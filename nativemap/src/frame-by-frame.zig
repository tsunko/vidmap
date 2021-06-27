const std = @import("std");

usingnamespace @cImport({
    @cInclude("libavcodec/avcodec.h");
    @cInclude("libavformat/avformat.h");
    @cInclude("libavutil/imgutils.h");
    @cInclude("libavutil/opt.h");
    @cInclude("libswscale/swscale.h");
});
usingnamespace @import("av-common.zig");

const alignment = @alignOf(u16);

pub fn FrameByFrame(comptime UserDataType: type) type {
    return struct {
        const Self = @This();

        codec: [*c]AVCodec = undefined,
        codecContext: [*c]AVCodecContext = undefined,
        formatContext: [*c]AVFormatContext = undefined,

        packet: [*c]AVPacket = undefined,
        inFrame: [*c]AVFrame = undefined,
        outFrame: [*c]AVFrame = undefined,
        swsContext: *SwsContext = undefined,

        videoIndex: u16 = 0,
        callback: ?fn ([*]const u8, UserDataType) void = null,
        userData: UserDataType = undefined,
        asyncFrame: @Frame(_stepNextFrame) = undefined,
        done: bool = false,

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
            self.videoIndex = findVideoStream(self.formatContext, &self.codecContext, &self.codec);
            if (self.videoIndex == comptime std.math.maxInt(u16)) {
                return AVError.NoStreamFound;
            }

            // open a codec for decoding
            if (avcodec_open2(self.codecContext, self.codec, null) < 0) {
                return AVError.FailedCodecOpen;
            }

            // zig fmt: off
            // allocate space for our output frame
            const outFrameBufferSize = av_image_get_buffer_size(
                AV_PIX_FMT_RGB444LE, 
                targetWidth, targetHeight, 
                alignment
            );
            const buffer = av_malloc(@intCast(usize, outFrameBufferSize) * @sizeOf(u8)).?;
            
            // then fill out our outFrame with suitable parameters for calling back to
            _ = av_image_fill_arrays(
                @ptrCast([*c][*c]u8, &self.outFrame.*.data[0]), 
                @ptrCast([*c]c_int, &self.outFrame.*.linesize[0]), 
                @ptrCast([*c]const u8, buffer), 
                AV_PIX_FMT_RGB444LE, 
                targetWidth, targetHeight, alignment
            );

            // to get this to compile with this, you have to copy and paste the function definition
            // of sws_alloc_set_opts into swscale.h, as swscale_internal.h isn't provided
            self.swsContext = sws_getContext(
                // source parameters
                self.codecContext.*.width, self.codecContext.*.height,
                self.codecContext.*.pix_fmt,

                // target parameters
                targetWidth, targetHeight,
                AV_PIX_FMT_RGB444LE,

                // scaling algorithm - use a crappy scaling algorithm because of performance
                SWS_POINT,
                null, null, null
            ) orelse return AVError.FailedSwrContextAlloc;

            self.asyncFrame = async self._stepNextFrame();
            self.done = false;
            // zig fmt: on

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
            resume self.asyncFrame;
            return true;
        }

        // internally the async function used for grabbing the next frame
        fn _stepNextFrame(self: *Self) void {
            // initially suspend
            suspend {}

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

                        // zig fmt: off
                        // more ugly pointer casting
                        _ = sws_scale(self.swsContext, 
                            @ptrCast([*c]const [*c]const u8, &self.inFrame.*.data[0]),  
                            @ptrCast([*c]const c_int, &self.inFrame.*.linesize[0]), 
                            0, 
                            self.codecContext.*.height, 
                            @ptrCast([*c]const [*c]u8, &self.outFrame.*.data[0]), 
                            @ptrCast([*c]c_int, &self.outFrame.*.linesize[0])
                        );

                        // zig fmt: on
                        // pass the frame and frame delay over to the callback function
                        self.callback.?(self.outFrame.*.data[0], self.userData);
                        suspend {}
                    }
                }
                av_packet_unref(self.packet);
            }

            self.done = true;
        }

        pub fn free(self: *Self) void {
            avcodec_free_context(&self.codecContext);
            avformat_close_input(&self.formatContext);
            av_packet_free(&self.packet);
            av_frame_free(&self.inFrame);
            av_frame_free(&self.outFrame);
            sws_freeContext(self.swsContext);
        }
    };
}

fn findVideoStream(formatContext: *AVFormatContext, contextOut: *[*c]AVCodecContext, codecOut: *[*c]AVCodec) u16 {
    var videoIndex: u16 = std.math.maxInt(u16);
    var i: u16 = 0;
    while (i < formatContext.*.nb_streams) : (i += 1) {
        const param: *AVCodecParameters = formatContext.*.streams[i].*.codecpar;
        const codec: [*c]AVCodec = avcodec_find_decoder(param.*.codec_id);
        // skip over unsupported codec
        if (codec == null) continue;

        if (param.*.codec_type == AVMEDIA_TYPE_VIDEO) {
            codecOut.* = codec;
            contextOut.* = avcodec_alloc_context3(codec);

            if (avcodec_parameters_to_context(contextOut.*, param) < 0) {
                // maybe try to find another one?
                continue;
            }

            // successfully found something
            videoIndex = i;
            break;
        }
    }

    return videoIndex;
}
