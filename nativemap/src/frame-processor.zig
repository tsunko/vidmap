const std = @import("std");
const tracy = @import("tracy.zig");
usingnamespace @import("threadpool");
usingnamespace @import("av-common.zig");

// we have to use 2 threads because sws_scale doesn't allow slicing in the middle for whatever reason
const PoolSize = 2;

pub fn FrameProcessor(comptime UserDataType: type) type {
    return struct {
        const CallbackFunction = fn ([*]const u8, ?UserDataType) void;
        const PoolType = ThreadPool(rescaleFrame, freeScaler);
        const Self = @This();

        formatContext: [*c]AVFormatContext = undefined,
        codecContext: [*c]AVCodecContext = undefined,

        packet: [*c]AVPacket = undefined,
        inFrame: [*c]AVFrame = undefined,
        outFrame: [*c]AVFrame = undefined,

        working: @Frame(__processNextFrame) = undefined,
        videoIndex: usize = undefined,
        callback: ?CallbackFunction = null,
        userData: ?UserDataType = null,
        scalingPool: *PoolType = undefined,

        started: bool = false,
        done: bool = false,

        pub fn open(self: *Self, source: [*:0]const u8, width: u16, height: u16) !f64 {
            if (avformat_alloc_context()) |formatContext| {
                self.formatContext = formatContext;
                errdefer avformat_close_input(&self.formatContext);
            } else {
                return error.AllocFailed;
            }

            if (av_frame_alloc()) |inFrame| {
                self.inFrame = inFrame;
                errdefer av_frame_free(&self.inFrame);
            } else {
                return error.AllocFailed;
            }

            if (av_frame_alloc()) |outFrame| {
                self.outFrame = outFrame;
                errdefer av_frame_free(&self.outFrame);
            } else {
                return error.AllocFailed;
            }

            if (av_packet_alloc()) |packet| {
                self.packet = packet;
                errdefer av_packet_free(&self.packet);
            } else {
                return error.AllocFailed;
            }

            if (avformat_open_input(&self.formatContext, source, null, null) < 0) {
                return error.OpenInputFailed;
            }

            if (avformat_find_stream_info(self.formatContext, null) < 0) {
                return error.NoStreamInfo;
            }

            var codec: [*c]AVCodec = undefined;
            self.videoIndex = try findVideoIndex(self.formatContext, &codec);

            self.codecContext = avcodec_alloc_context3(codec);
            errdefer avcodec_free_context(&self.codecContext);

            if (avcodec_parameters_to_context(self.codecContext, self.formatContext.*.streams[self.videoIndex].*.codecpar) < 0) {
                return error.CodecParamConversionFailed;
            }

            if (avcodec_open2(self.codecContext, codec, null) < 0) {
                return error.CodecOpenFailed;
            }

            try populateOutFrame(self.outFrame, width, height);

            self.scalingPool = try PoolType.init(std.heap.c_allocator, PoolSize);

            self.started = false;
            self.done = false;

            return 1000.0 * (1.0 / av_q2d(self.formatContext.*.streams[self.videoIndex].*.r_frame_rate));
        }

        pub fn processNextFrame(self: *Self) bool {
            if (self.done) {
                return false;
            }

            if (self.started) {
                resume self.working;
            } else {
                self.working = async self.__processNextFrame();
                self.started = true;
            }
            return true;
        }

        fn __processNextFrame(self: *Self) void {
            if (self.done) return;

            while (av_read_frame(self.formatContext, self.packet) == 0) {
                if (self.packet.*.stream_index == self.videoIndex) {
                    if (avcodec_send_packet(self.codecContext, self.packet) < 0) {
                        self.done = true;
                        return;
                    }

                    while (true) {
                        const response = avcodec_receive_frame(self.codecContext, self.inFrame);
                        if (response == AVERROR(EAGAIN) or response == AVERROR_EOF) {
                            break;
                        } else if (response < 0) {
                            self.done = true;
                            return;
                        }

                        const tracy_scale = tracy.ZoneN(@src(), "Scaling");
                        var start: c_int = 0;
                        var end: c_int = 0;
                        var offsetMul: c_int = 1;
                        while (offsetMul <= PoolSize) : (offsetMul += 1) {
                            start = end;
                            end = @divFloor((self.inFrame.*.height * offsetMul), PoolSize);
                            self.scalingPool.submitTask(.{
                                self.inFrame,
                                self.outFrame,
                                start,
                                end - start,
                            }) catch @panic("Failed to submit scaling task");
                        }
                        self.scalingPool.awaitTermination() catch |err| {
                            if (err == error.Forced) {
                                self.done = true;
                                return;
                            } else {
                                @panic("awaitTermination error: not forced?");
                            }
                        };
                        tracy_scale.End();

                        if (self.callback) |cb| {
                            const tracy_callback = tracy.ZoneN(@src(), "Callback");
                            @call(.{}, cb, .{ self.outFrame.*.data[0], self.userData });
                            tracy_callback.End();
                        }

                        suspend {}
                    }
                }
                av_packet_unref(self.packet);
            }

            self.done = true;
        }

        pub fn close(self: *Self) !void {
            self.scalingPool.shutdown();
            avcodec_free_context(&self.codecContext);
            avformat_close_input(&self.formatContext);
            av_packet_free(&self.packet);
            av_frame_free(&self.inFrame);
            av_frame_free(&self.outFrame);
            // we need to free scaler, but i'm not exactly sure how?
            // just leak it for now, figure it out later
        }
    };
}

fn findVideoIndex(formatContext: [*c]AVFormatContext, codec: *[*c]AVCodec) !usize {
    var tmpIndex = av_find_best_stream(formatContext, AVMEDIA_TYPE_VIDEO, -1, -1, codec, 0);
    if (tmpIndex < 0) {
        return error.NoSuitableStream;
    }
    return @intCast(usize, tmpIndex);
}

fn populateOutFrame(outFrame: [*c]AVFrame, width: u16, height: u16) !void {
    const alignment = @alignOf(u16);
    const bufferSize = av_image_get_buffer_size(
        AV_PIX_FMT_RGB444LE,
        width,
        height,
        alignment,
    );

    if (bufferSize < 0) {
        return error.AllocFailed;
    }

    if (av_malloc(@intCast(usize, bufferSize) * @sizeOf(u8))) |buffer| {
        errdefer av_freep(buffer);

        if (av_image_fill_arrays(
            @ptrCast([*c][*c]u8, &outFrame.*.data[0]),
            @ptrCast([*c]c_int, &outFrame.*.linesize[0]),
            @ptrCast([*c]const u8, buffer),
            AV_PIX_FMT_RGB444LE,
            width,
            height,
            alignment,
        ) < 0) {
            return error.AllocFailed;
        }

        outFrame.*.width = width;
        outFrame.*.height = height;
        outFrame.*.format = AV_PIX_FMT_RGB444LE;
    } else {
        return error.AllocFailed;
    }
}

threadlocal var scaler: ?*SwsContext = null;
fn rescaleFrame(in: [*c]AVFrame, out: [*c]AVFrame, y: c_int, h: c_int) void {
    if (scaler == null) {
        scaler = sws_getContext(
            // source parameters
            in.*.width,
            in.*.height,
            in.*.format,

            // target parameters
            out.*.width,
            out.*.height,
            // note, if it crashes, i'm a dipshit and populateOutFrame doesn't set this
            out.*.format,

            SWS_POINT,
            null,
            null,
            null,
        ) orelse @panic("Failed scaler context creation");
    }

    var inSlicedPlanes: [8][*c]u8 = undefined;

    // populate inSlicedPlanes with... planes that are sliced
    // we can't just add offsets and be done with it because of formats like YUV,
    // where U and V has half the amount of Y's.
    var plane: usize = 0;
    while (plane < av_pix_fmt_count_planes(in.*.format)) : (plane += 1) {
        var vsub: u5 = undefined;

        if ((plane + 1) & 2 > 0) {
            const fmt = av_pix_fmt_desc_get(in.*.format);
            vsub = @truncate(u5, fmt.*.log2_chroma_h);
        } else {
            vsub = 0;
        }

        const inOffset = (y >> vsub) * in.*.linesize[plane];
        inSlicedPlanes[plane] = addDataOffset(in.*.data[plane], @intCast(usize, inOffset));
    }

    if (sws_scale(
        scaler,
        @ptrCast([*c]const [*c]const u8, &inSlicedPlanes[0]),
        @ptrCast([*c]const c_int, &in.*.linesize[0]),
        y,
        h,
        @ptrCast([*c]const [*c]u8, &out.*.data[0]),
        @ptrCast([*c]c_int, &out.*.linesize[0]),
    ) < 0) {
        @panic("Failed to scale");
    }
}

fn freeScaler() void {
    sws_freeContext(scaler);
}

inline fn addDataOffset(src: [*c]u8, offset: usize) [*c]u8 {
    return @intToPtr([*c]u8, @ptrToInt(src) + offset);
}
