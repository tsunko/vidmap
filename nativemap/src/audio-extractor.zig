const std = @import("std");
usingnamespace @import("av-common.zig");

const SourceFile = struct {
    formatContext: [*c]AVFormatContext = undefined,
    codecContext: [*c]AVCodecContext = undefined,
    frame: [*c]AVFrame = undefined,
    packet: [*c]AVPacket = undefined,

    streamIndex: usize = undefined,

    pub fn close(self: *@This()) void {
        avformat_close_input(&self.*.formatContext);
        avcodec_free_context(&self.*.codecContext);
        av_frame_free(&self.*.frame);
        av_free_packet(self.*.packet);
    }
};

const DestinationFile = struct {
    formatContext: [*c]AVFormatContext = undefined,
    codecContext: [*c]AVCodecContext = undefined,
    frame: [*c]AVFrame = undefined,
    packet: [*c]AVPacket = undefined,

    pub fn close(self: *@This()) void {
        avformat_close_output(&self.*.formatContext);
        avcodec_free_context(&self.*.codecContext);
        av_frame_free(&self.*.frame);
        av_free_packet(self.*.packet);
    }
};

pub fn extractAudio(srcPath: [*:0]const u8, dstPath: [*:0]const u8) !void {
    var src: SourceFile = .{};
    var dst: DestinationFile = .{};
    
    try openSourceFile(srcPath, &src);
    defer src.close();
    
    try openDestinationFile(dstPath, &dst);
    defer dst.close();

    var swrContext = try createSwrContext(src.codecContext, dst.codecContext);
    defer swr_free(&swrContext);

    while (av_read_frame(src.formatContext, src.packet) >= 0) {
        if (src.packet.*.stream_index == src.streamIndex) {
            if (avcodec_send_packet(src.codecContext, src.packet) < 0) {
                return error.BadResponse;
            }
            
            while (true) {
                var response = avcodec_receive_frame(src.codecContext, src.frame);
                if (response == AVERROR(EAGAIN) or response == AVERROR_EOF) {
                    break;
                } else if (response < 0) {
                    return error.BadResponse;
                }

                // convert and encode the first part of the audio frame
                if (swr_convert_frame(swrContext, dst.frame, src.frame) < 0) {
                    return error.FailedConversion;
                }
                try encode(&src, &dst, false);

                // drain encoder since some stuff can be lingering in buffer
                while (swr_get_delay(swrContext, dst.codecContext.*.sample_rate) > dst.frame.*.nb_samples) {
                    if (swr_convert(swrContext, @ptrCast([*c][*c]u8, &dst.frame.*.data[0]), dst.frame.*.nb_samples, null, 0) < 0) {
                        return error.FailedConversion;
                    }

                    try encode(&src, &dst, false);
                }
            }
        }
        av_packet_unref(src.packet);
    }

    // flush encoder
    try encode(&src, &dst, true);
}

fn openSourceFile(srcPath: [*:0]const u8, src: *SourceFile) !void {
    if (avformat_alloc_context()) |formatContext| {
        src.*.formatContext = formatContext;
        errdefer avformat_close_input(src.*.formatContext);
    } else {
        return error.AllocFailed;
    }

    if (avformat_open_input(&src.*.formatContext, srcPath, null, null) < 0) {
        return error.OpenInputFailed;
    }

    if (avformat_find_stream_info(src.*.formatContext, null) < 0) {
        return error.NoStreamInfo;
    }

    var codec: [*c]AVCodec = undefined;
    var tmpIndex = av_find_best_stream(src.*.formatContext, AVMEDIA_TYPE_AUDIO, -1, -1, &codec, 0);
    if (tmpIndex < 0) {
        return error.NoSuitableStream;
    }
    src.*.streamIndex = @intCast(usize, tmpIndex);

    if (avcodec_alloc_context3(codec)) |codecContext| {
        src.*.codecContext = codecContext;
        errdefer avcodec_free_context(&src.*.codecContext);
    } else {
        return error.AllocFailed;
    }

    var codecpar = src.*.formatContext.*.streams[src.*.streamIndex].*.codecpar;
    if (avcodec_parameters_to_context(src.*.codecContext, codecpar) < 0) {
        return error.CodecParamConversionFailed;
    }

    if (avcodec_open2(src.*.codecContext, codec, null) < 0) {
        return error.CodecOpenFailed;
    }

    src.*.frame = try createFrameWithContext(src.*.codecContext);
    errdefer av_frame_free(&src.*.frame);

    if (av_packet_alloc()) |packet| {
        src.*.packet = packet;
    } else {
        return error.AllocFailed;
    }
}

fn openDestinationFile(dstPath: [*:0]const u8, dst: *DestinationFile) !void {
    var outputFormat = av_guess_format(null, dstPath, null);
    if (outputFormat == null) {
        return error.GuessFormatFailed;
    }

    if (avformat_alloc_output_context2(&dst.*.formatContext, outputFormat, null, dstPath) < 0) {
        return error.AllocFailed;
    }
    errdefer avformat_close_output(&dst.*.formatContext);

    var encoder = avcodec_find_encoder(AV_CODEC_ID_VORBIS);
    if (encoder == null) {
        return error.NoVorbisEncoder;
    }

    var stream = avformat_new_stream(dst.*.formatContext, encoder);
    if (stream == null) {
        return error.AllocFailed;
    }

    dst.*.codecContext = stream.*.codec;
    dst.*.codecContext.*.codec_id = AV_CODEC_ID_VORBIS;
    dst.*.codecContext.*.codec_type = AVMEDIA_TYPE_AUDIO;
    dst.*.codecContext.*.bit_rate = 64000;
    dst.*.codecContext.*.channels = 2;
    dst.*.codecContext.*.channel_layout = AV_CH_LAYOUT_STEREO;
    dst.*.codecContext.*.sample_rate = 44100;
    dst.*.codecContext.*.sample_fmt = encoder.*.sample_fmts[0];
    dst.*.codecContext.*.time_base = AVRational{ .num = 1, .den = 44100 };
    
    if (avcodec_open2(dst.*.codecContext, encoder, null) < 0) {
        return error.CodecOpenFailed;
    }
    
    if (avcodec_parameters_from_context(stream.*.codecpar, dst.*.codecContext) < 0) {
        return error.CodecParamConversionFailed;
    }
    
    if (avio_open(&dst.*.formatContext.*.pb, dstPath, AVIO_FLAG_WRITE) < 0) {
        return error.AvioOpenFailed;
    }
    
    if (avformat_write_header(dst.*.formatContext, null) < 0) {
        return error.AvioWriteHeaderFailed;
    }

    dst.*.frame = try createFrameWithContext(dst.*.codecContext);
    errdefer av_frame_free(&dst.*.frame);

    if (av_packet_alloc()) |packet| {
        dst.*.packet = packet;
    } else {
        return error.AllocFailed;
    }
}

fn createFrameWithContext(context: [*c]AVCodecContext) ![*c]AVFrame {
    if (av_frame_alloc()) |frame| {
        frame.*.nb_samples = context.*.frame_size;
        frame.*.format = context.*.sample_fmt;
        frame.*.channel_layout = context.*.channel_layout;
        frame.*.channels = context.*.channels;
        frame.*.sample_rate = context.*.sample_rate;
        if (av_frame_get_buffer(frame, 0) < 0) {
            return error.AllocFailed;
        }
        return frame;
    } else {
        return error.AllocFailed;
    }
}

fn createSwrContext(srcContext: [*c]AVCodecContext, dstContext: [*c]AVCodecContext) !?*SwrContext {
    var context = swr_alloc_set_opts(
        null,

        @intCast(i64, dstContext.*.channel_layout),
        dstContext.*.sample_fmt,
        dstContext.*.sample_rate,

        @intCast(i64, srcContext.*.channel_layout),
        srcContext.*.sample_fmt,
        srcContext.*.sample_rate,

        0,
        null,
    );

    if (swr_init(context) < 0) {
        return error.AllocFailed;
    }

    return context;
}

fn encode(src: *SourceFile, dst: *DestinationFile, flush: bool) !void {
    if (avcodec_send_frame(dst.*.codecContext, if (flush) null else dst.*.frame) < 0) {
        return error.BadResponse;
    }

    while (true) {
        var response = avcodec_receive_packet(dst.*.codecContext, dst.*.packet);
        if (response == AVERROR(EAGAIN) or response == AVERROR_EOF) {
            break;
        } else if (response < 0) {
            return error.BadResponse;
        }

        dst.*.packet.*.pts = src.*.packet.*.pts;
        dst.*.packet.*.dts = src.*.packet.*.dts;
        dst.*.packet.*.pos = -1;

        if (av_interleaved_write_frame(dst.*.formatContext, dst.*.packet) < 0) {
            return error.FailedEncode;
        }

        av_packet_unref(dst.*.packet);
    }
}

fn avformat_close_output(format: *[*c]AVFormatContext) void {
    if (av_write_trailer(format.*) < 0) {
        std.log.warn("av_write_trailer: leak", .{});
    }

    if (avio_closep(&format.*.*.pb) < 0) {
        std.log.warn("avio_closep: leak", .{});
    }

    format.* = 0;
}
