const std = @import("std");
const tracy = @import("tracy.zig");

usingnamespace @import("av-common.zig");
usingnamespace @import("stride-pool.zig");

// unfortunately, due to how swscale is written, you cannot actually do more than 2
// slices at once. it just ends up complaining about "slicing in the middle" or downright segfaults
const poolSize = 2;
// alignment for our image data, which... may not matter because of how slicing works
const alignment = @alignOf(u16);

pub fn FrameByFrame(comptime UserDataType: type) type {
    return struct {
        const PoolType = StrideRescalePool(poolSize);
        const Self = @This();

        codec: [*c]AVCodec = undefined,
        codecContext: [*c]AVCodecContext = undefined,
        formatContext: [*c]AVFormatContext = undefined,

        packet: [*c]AVPacket = undefined,
        inFrame: [*c]AVFrame = undefined,
        outFrame: [*c]AVFrame = undefined,

        scalingPool: PoolType = undefined,
        scaler: *SwsContext = undefined,

        videoIndex: usize = 0,
        callback: ?fn ([*]const u8, UserDataType) void = null,
        userData: UserDataType = undefined,
        asyncFrame: @Frame(_stepNextFrame) = undefined,
        done: bool = false,
        started: bool = false,

        pub fn setup(self: *Self, source: [*:0]const u8, targetWidth: u16, targetHeight: u16) !f64 {
            self.formatContext = avformat_alloc_context();

            self.inFrame = av_frame_alloc();
            self.outFrame = av_frame_alloc();

            self.packet = av_packet_alloc();
            av_init_packet(self.packet);

            // try to simply open it and look at it's format
            if (avformat_open_input(&self.formatContext, source, null, null) != 0) {
                return AVError.FailedOpenInput;
            }

            // locate all stream information
            if (avformat_find_stream_info(self.formatContext, null) < 0) {
                return AVError.FailedFindStreamInfo;
            }

            // then filter all streams to find the video stream (we assume it's the first one found)
            var index = av_find_best_stream(self.formatContext, AVMEDIA_TYPE_VIDEO, -1, -1, &self.codec, 0);
            if (index < 0) {
                return AVError.NoStreamFound;
            }
            self.videoIndex = @intCast(usize, index);

            self.codecContext = avcodec_alloc_context3(self.codec);
            if (avcodec_parameters_to_context(self.codecContext, self.formatContext.*.streams[self.videoIndex].*.codecpar) < 0) {
                return AVError.FailedFindStreamInfo;
            }

            // open a codec for decoding
            if (avcodec_open2(self.codecContext, self.codec, null) < 0) {
                return AVError.FailedCodecOpen;
            }

            // allocate space for our output frame
            const outFrameBufferSize = av_image_get_buffer_size(
                AV_PIX_FMT_RGB444LE,
                targetWidth,
                targetHeight,
                alignment,
            );
            const buffer = av_malloc(@intCast(usize, outFrameBufferSize) * @sizeOf(u8)).?;

            // then fill out our outFrame with suitable parameters for calling back to
            _ = av_image_fill_arrays(
                @ptrCast([*c][*c]u8, &self.outFrame.*.data[0]),
                @ptrCast([*c]c_int, &self.outFrame.*.linesize[0]),
                @ptrCast([*c]const u8, buffer),
                AV_PIX_FMT_RGB444LE,
                targetWidth,
                targetHeight,
                alignment,
            );

            self.scaler = sws_getContext(
                // source parameters
                self.codecContext.*.width,
                self.codecContext.*.height,
                self.codecContext.*.pix_fmt,

                // target parameters
                targetWidth,
                targetHeight,
                AV_PIX_FMT_RGB444LE,

                // scaling algorithm - use a crappy scaling algorithm because of performance
                SWS_POINT,
                null,
                null,
                null,
            ) orelse return AVError.FailedSwrContextAlloc;

            try self.scalingPool.init(targetWidth, targetHeight);
            self.done = false;

            // return frame delay
            return 1000.0 * (1.0 / av_q2d(self.formatContext.*.streams[self.videoIndex].*.r_frame_rate));
        }

        pub fn getWidth(self: *Self) u16 {
            return @intCast(u16, self.codecContext.*.width);
        }

        pub fn getHeight(self: *Self) u16 {
            return @intCast(u16, self.codecContext.*.height);
        }

        // wrapper function for resuming the internal probably-suspended function
        pub fn stepNextFrame(self: *Self) bool {
            if (self.done) return false;
            if (!self.started) {
                self.asyncFrame = async self._stepNextFrame();
                self.started = true;
            } else {
                resume self.asyncFrame;
            }
            return true;
        }

        // internally the async function used for grabbing the next frame
        fn _stepNextFrame(self: *Self) void {
            if (self.callback == null or self.done) {
                self.done = true;
                return;
            }

            while (av_read_frame(self.formatContext, self.packet) == 0) {
                if (self.packet.*.stream_index == self.videoIndex) {
                    var response = avcodec_send_packet(self.codecContext, self.packet);
                    if (response < 0) {
                        self.done = true;
                        return;
                    }

                    while (response >= 0) {
                        response = avcodec_receive_frame(self.codecContext, self.inFrame);
                        if (response == AVERROR(EAGAIN) or response == AVERROR_EOF) {
                            break;
                        } else if (response < 0) {
                            self.done = true;
                            return;
                        }

                        const tracy_scale = tracy.ZoneN(@src(), "scale");
                        // a lot of the slice calculation code is directly pulled from FFmpeg's vf_scale.c
                        {
                            var i: c_int = 0;
                            var slice_h: c_int = 0;
                            var slice_start: c_int = 0;
                            var slice_end: c_int = 0;
                            while (i < poolSize) : (i += 1) {
                                slice_start = slice_end;
                                slice_end = @divExact(self.inFrame.*.height * (i + 1), poolSize);
                                slice_h = slice_end - slice_start;

                                self.scalingPool.submitTask(.{
                                    .in = self.inFrame,
                                    .out = self.outFrame,
                                    .y = slice_start,
                                    .h = slice_h,
                                }) catch @panic("failed to submit slice task?");
                            }

                            // wait for our pool to empty completely
                            self.scalingPool.waitUntilEmpty() catch |err| if (err == error.Forced) return else @panic("???");
                        }

                        tracy_scale.End();

                        const tracy_callback = tracy.ZoneN(@src(), "callback");
                        // pass the frame and frame delay over to the callback function
                        self.callback.?(self.outFrame.*.data[0], self.userData);
                        tracy_callback.End();

                        suspend {}
                    }
                }
                av_packet_unref(self.packet);
            }

            self.done = true;
        }

        pub fn free(self: *Self) void {
            self.scalingPool.shutdown();
            avcodec_free_context(&self.codecContext);
            avformat_close_input(&self.formatContext);
            av_packet_free(&self.packet);
            av_frame_free(&self.inFrame);
            av_frame_free(&self.outFrame);
            sws_freeContext(self.scaler);
        }
    };
}
