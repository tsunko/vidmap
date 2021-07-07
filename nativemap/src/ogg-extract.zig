const std = @import("std");

usingnamespace @cImport({
    @cInclude("libswresample/swresample.h");
    @cInclude("libavcodec/avcodec.h");
    @cInclude("libavformat/avformat.h");
    @cInclude("libavutil/opt.h");
});
usingnamespace @import("av-common.zig");

pub fn findAndConvertAudio(inFile: [*:0]const u8, outFile: [*:0]const u8) !void {
    var inFormatContext: [*c]AVFormatContext = undefined;
    var inCodecContext: [*c]AVCodecContext = undefined;
    var inStreamId: usize = undefined;

    var outFormatContext: [*c]AVFormatContext = undefined;
    var outCodecContext: [*c]AVCodecContext = undefined;

    // open our input and output files for read/writing
    try openInputFile(inFile, &inFormatContext, &inCodecContext, &inStreamId);
    defer cleanupContexts(inFormatContext, inCodecContext, false);

    try openOutputFile(outFile, &outFormatContext, &outCodecContext, inCodecContext);
    defer cleanupContexts(outFormatContext, outCodecContext, true);

    var swrContext = try createSWRContext(inCodecContext, outCodecContext);
    defer swr_free(&swrContext);

    var inFrame = try createFrameWithContext(inCodecContext);
    var outFrame = try createFrameWithContext(outCodecContext);
    defer av_frame_free(&inFrame);
    defer av_frame_free(&outFrame);

    var inPacket = av_packet_alloc();
    var outPacket = av_packet_alloc();
    defer av_free_packet(inPacket);
    defer av_free_packet(outPacket);

    while (av_read_frame(inFormatContext, inPacket) >= 0) {
        if (inPacket.*.stream_index == inStreamId) {
            var response = avcodec_send_packet(inCodecContext, inPacket);
            if (response < 0) {
                return AVError.BadResponse;
            }

            while (response >= 0) {
                response = avcodec_receive_frame(inCodecContext, inFrame);
                if (response == AVERROR(EAGAIN) or response == AVERROR_EOF) {
                    break;
                } else if (response < 0) {
                    return AVError.BadResponse;
                }

                // do an initial frame conversion
                if (swr_convert_frame(swrContext, outFrame, inFrame) < 0) {
                    return AVError.FailedConversion;
                }
                try encode(outFormatContext, outCodecContext, outFrame, outPacket, inPacket);

                // then drain swresample
                while (swr_get_delay(swrContext, outCodecContext.*.sample_rate) > outFrame.*.nb_samples) {
                    if (swr_convert(swrContext, @ptrCast([*c][*c]u8, &outFrame.*.data[0]), outFrame.*.nb_samples, null, 0) < 0) {
                        return AVError.FailedConversion;
                    }

                    try encode(outFormatContext, outCodecContext, outFrame, outPacket, inPacket);
                }
            }
        }

        av_packet_unref(inPacket);
    }

    // flush the encoder out
    try encode(outFormatContext, outCodecContext, null, outPacket, inPacket);
}

fn openInputFile(inFile: [*:0]const u8, inFmtContext: *[*c]AVFormatContext, inCodecContext: *[*c]AVCodecContext, streamId: *usize) !void {
    var formatContext: [*c]AVFormatContext = avformat_alloc_context();
    var codecContext: [*c]AVCodecContext = undefined;
    var codec: [*c]AVCodec = undefined;
    var id: usize = undefined;

    if (avformat_open_input(&formatContext, inFile, null, null) != 0) {
        return AVError.FailedOpenInput;
    }
    inFmtContext.* = formatContext;

    if (avformat_find_stream_info(formatContext, null) < 0) {
        return AVError.FailedFindStreamInfo;
    }

    id = @intCast(usize, av_find_best_stream(formatContext, AVMEDIA_TYPE_AUDIO, -1, -1, &codec, 0));
    streamId.* = id;
    if (id < 0) {
        return AVError.NoStreamFound;
    }

    codecContext = avcodec_alloc_context3(codec);
    inCodecContext.* = codecContext;
    if (avcodec_parameters_to_context(codecContext, formatContext.*.streams[id].*.codecpar) < 0) {
        return AVError.FailedFindStreamInfo;
    }

    if (avcodec_open2(codecContext, codec, null) < 0) {
        return AVError.FailedCodecOpen;
    }
}

fn openOutputFile(outFile: [*:0]const u8, outFmtContext: *[*c]AVFormatContext, outCodecContext: *[*c]AVCodecContext, inCodecContext: [*c]AVCodecContext) !void {
    var outputFormat: [*c]AVOutputFormat = undefined;
    var formatContext: [*c]AVFormatContext = undefined;
    var codecContext: [*c]AVCodecContext = undefined;
    var codec: [*c]AVCodec = undefined;
    var stream: [*c]AVStream = undefined;

    outputFormat = av_guess_format(null, outFile, null);
    if (outputFormat == null) {
        return AVError.FailedGuessingFormat;
    }

    if (avformat_alloc_output_context2(&formatContext, outputFormat, null, outFile) < 0) {
        return AVError.FailedGuessingFormat;
    }
    outFmtContext.* = formatContext;

    stream = try createAudioStream(formatContext, inCodecContext);

    codecContext = stream.*.codec;
    outCodecContext.* = codecContext;

    codec = avcodec_find_encoder(codecContext.*.codec_id);
    if (codec == null) {
        return AVError.FailedFindCodec;
    }

    if (avcodec_open2(codecContext, codec, null) < 0) {
        return AVError.FailedCodecOpen;
    }

    _ = avcodec_parameters_from_context(stream.*.codecpar, codecContext);

    if (avio_open(&formatContext.*.pb, outFile, AVIO_FLAG_WRITE) < 0) {
        return AVError.FailedAvioOpen;
    }

    if (avformat_write_header(formatContext, null) < 0) {
        return AVError.FailedCodecOpen;
    }
}

fn createAudioStream(format: [*c]AVFormatContext, inCodecContext: [*c]AVCodecContext) ![*c]AVStream {
    var encoder = avcodec_find_encoder(AV_CODEC_ID_VORBIS);
    var stream = avformat_new_stream(format, encoder);

    if (stream == null) {
        return AVError.FailedStreamCreation;
    }

    // TODO: convert to codecpar
    const codecContext = stream.*.codec;
    codecContext.*.codec_id = AV_CODEC_ID_VORBIS;
    codecContext.*.codec_type = AVMEDIA_TYPE_AUDIO;
    codecContext.*.bit_rate = inCodecContext.*.bit_rate;
    codecContext.*.channels = inCodecContext.*.channels;
    codecContext.*.channel_layout = inCodecContext.*.channel_layout;
    codecContext.*.sample_rate = inCodecContext.*.sample_rate;
    codecContext.*.sample_fmt = encoder.*.sample_fmts[0];
    codecContext.*.time_base = AVRational{ .num = 1, .den = inCodecContext.*.sample_rate };
    return stream;
}

fn createSWRContext(inCodecContext: [*c]AVCodecContext, outCodecContext: [*c]AVCodecContext) !?*SwrContext {
    // zig fmt: off
    var context = swr_alloc_set_opts(
        null,
        @intCast(i64, outCodecContext.*.channel_layout),
        outCodecContext.*.sample_fmt,
        outCodecContext.*.sample_rate,

        @intCast(i64, inCodecContext.*.channel_layout),
        inCodecContext.*.sample_fmt,
        inCodecContext.*.sample_rate,

        0, null
    );
    // zig fmt: on

    if (swr_init(context) < 0) {
        return AVError.FailedSwrContextAlloc;
    }

    return context;
}

fn createFrameWithContext(context: [*c]AVCodecContext) ![*c]AVFrame {
    var frame = av_frame_alloc();

    if (frame == null) {
        return AVError.FailedFrameAlloc;
    }

    frame.*.nb_samples = context.*.frame_size;
    frame.*.format = context.*.sample_fmt;
    frame.*.channel_layout = context.*.channel_layout;
    frame.*.channels = context.*.channels;
    frame.*.sample_rate = context.*.sample_rate;

    if (av_frame_get_buffer(frame, 0) < 0) {
        return AVError.FailedFrameAlloc;
    }

    return frame;
}

fn encode(formatContext: [*c]AVFormatContext, codecContext: [*c]AVCodecContext, frame: [*c]AVFrame, outPacket: [*c]AVPacket, inPacket: [*c]AVPacket) !void {
    var response = avcodec_send_frame(codecContext, frame);
    if (response < 0) {
        return AVError.BadResponse;
    }

    while (response >= 0) {
        response = avcodec_receive_packet(codecContext, outPacket);
        if (response == AVERROR(EAGAIN) or response == AVERROR_EOF) {
            break;
        } else if (response < 0) {
            return AVError.BadResponse;
        }

        // since we're basically just copying the audio at the same sample rate
        // we can get away with just copying pts and dts from the incoming data
        outPacket.*.pts = inPacket.*.pts;
        outPacket.*.dts = inPacket.*.dts;
        outPacket.*.pos = -1;

        if (av_interleaved_write_frame(formatContext, outPacket) < 0) {
            return AVError.FailedEncode;
        }
        av_packet_unref(outPacket);
    }
}

fn cleanupContexts(format: [*c]AVFormatContext, codec: [*c]AVCodecContext, isOutput: bool) void {
    if (isOutput) {
        // write out trailer
        if (av_write_trailer(format) < 0) {
            std.log.warn("av_write_trailer leak", .{});
        }

        // close and (implicitly) flush our output
        if (avio_closep(&format.*.pb) < 0) {
            std.log.warn("out: avio_closep leak", .{});
        }
    }

    if (!isOutput) {
        avformat_close_input(&(&format.*));
    }

    _ = avcodec_close(codec);
    avcodec_free_context(&(&codec.*));
}
