const std = @import("std");
const ztracy = @import("ztracy");
const c = @cImport({
    // we do this also in sdl_viewer.zig...
    @cDefine("__builtin_va_arg_pack", "((void (*)())(0xDEADC0DE))");
    @cInclude("libavcodec/avcodec.h");
    @cInclude("libavformat/avformat.h");
    @cInclude("libswscale/swscale.h");
    @cInclude("libswresample/swresample.h");
    @cInclude("libavutil/imgutils.h");
    @cInclude("libavutil/opt.h");

    // these two macros don't translate properly from c - use a workaround header to redefine them
    @cUndef("AV_CHANNEL_LAYOUT_MASK");
    @cUndef("MKTAG");
    @cInclude("libav_workarounds.h");
});

const Lut = @import("Lut.zig");

//nativemap_global_init   ([*c]u8)                            bool        false = failed to load lut, true = otherwise
//nativemap_alloc_context (short w, short h)                  *Context    nullptr = failed to alloc context, ptr otherwise
//nativemap_open_input    (*Context, [*c]u8, [*c]f64)         int         <0 = error, >=0 = success, writes timescale to double ptr
//nativemap_read_frame    (*Context, [*c]long)                int         <0 = error, 0 = end of stream, >0 = success, also write pts to long ptr
//nativemap_adjust_output (*Context, short w, short h)        int         <0 = error, >=0 = success
//nativemap_free_context  (*Context)                          void        nothing

const Self = @This();
const assert = std.debug.assert;

const OUTPUT_SAMPLE_RATE = 44100;
const OUTPUT_BIT_RATE = 64000;

pub const Dimensions = union(enum) {
    map: struct { width: u16, height: u16 },
    pixel: struct { width: usize, height: usize },

    pub fn size(d: Dimensions) usize {
        return switch (d) {
            .map => |m| @as(usize, @intCast(m.width)) * @as(usize, @intCast(m.height)) * 128 * 128,
            .pixel => |p| p.width * p.height,
        };
    }
};

pub const AvState = struct {
    /// The packet we use for reading in data
    packet: *c.AVPacket,
    /// Source decoded frame from file
    srcFrame: *c.AVFrame,
    /// Converted frame after swscale/swresample
    cvtFrame: *c.AVFrame,

    /// Format context for input file
    fmtContext: *c.AVFormatContext,
    /// The conversion context
    cvtContext: union(enum) {
        video: *c.SwsContext,
        audio: *c.SwrContext,
    },

    /// The stream index for the media we want to decode
    index: usize,
    /// Codec context for actually decoding
    codecContext: *c.AVCodecContext,
    /// If we have to resend the current packet
    resend: bool,
};

buffer: []u8,
dimensions: Dimensions,
av: ?AvState = null,

pub fn open(self: *Self, src: []const u8) !f64 {
    // create a format context and try to guess some preliminary information about the source
    var fmtContext: ?*c.AVFormatContext = null;
    try _check(c.avformat_open_input(&fmtContext, src.ptr, null, null));
    errdefer c.avformat_close_input(&fmtContext);

    // search the file for for stream information - have to call this because MPEG doesn't have headers to describe them
    try _check(c.avformat_find_stream_info(fmtContext, null));

    // allocate structs used for decoding and scaling
    var packet: *c.AVPacket = try _nonnull(c.av_packet_alloc());
    errdefer c.av_packet_free(@ptrCast(&packet));

    var srcFrame: *c.AVFrame = try _nonnull(c.av_frame_alloc());
    errdefer c.av_frame_free(@ptrCast(&srcFrame));

    var cvtFrame: *c.AVFrame = try _nonnull(c.av_frame_alloc());
    errdefer c.av_frame_free(@ptrCast(&cvtFrame));

    // if we're expressing size in maps, convert it to pixels
    const size = dimensionToPixel(self.dimensions).pixel;

    // initialize the frame we use with sws_scale
    cvtFrame.width = @intCast(size.width);
    cvtFrame.height = @intCast(size.height);
    cvtFrame.format = c.AV_PIX_FMT_GBRP;
    try _check(c.av_frame_get_buffer(cvtFrame, 0));

    // initialize the video codec context and prepare it for decoding video streams
    const index, const codec, var codecContext = try findBestStream(fmtContext.?, c.AVMEDIA_TYPE_VIDEO)
        orelse return AvError.StreamNotFound; // if no video stream is found, why are we trying to playback videos...
    errdefer c.avcodec_free_context(@ptrCast(&codecContext));

    // copy parameters so we decode this properly
    try _check(c.avcodec_parameters_to_context(codecContext, fmtContext.?.streams[index].*.codecpar));

    // set decoder to use multithreading when applicable, and to decode multiple slices of a single frame at once
    codecContext.thread_count = 0;
    codecContext.thread_type = c.FF_THREAD_SLICE;

    // open the codec for operation
    try _check(c.avcodec_open2(codecContext, codec, null));

    // initialize sws_scale for scaling the input video frames into the correct size and pixel format
    var swsContext = try sws_alloc_multithread(
        // src frame properties
        codecContext.width, codecContext.height, codecContext.pix_fmt,
        // dst frame properties
        @intCast(size.width), @intCast(size.height), c.AV_PIX_FMT_GBRP,
    );

    errdefer c.sws_free_context(&swsContext);

    self.av = .{
        .packet = packet,
        .srcFrame = srcFrame,
        .cvtFrame = cvtFrame,
        .fmtContext = fmtContext.?,
        .cvtContext = .{ .video = swsContext },
        .index = index,
        .codecContext = codecContext,
        .resend = false,
    };
    return c.av_q2d(fmtContext.?.streams[index].*.time_base);
}

pub fn extractAudio(self: *Self, outputPath: []const u8) !i32 {
    const inAv = &self.av.?;
    // find and instantiate a codec context for the audio stream
    const inIdx, const inCodec, var inCodecContext = (try findBestStream(inAv.fmtContext, c.AVMEDIA_TYPE_AUDIO))
        orelse return 0; // return no audio stream available
    try _check(c.avcodec_parameters_to_context(inCodecContext, inAv.fmtContext.streams[inIdx].*.codecpar));
    try _check(c.avcodec_open2(inCodecContext, inCodec, null));
    defer c.avcodec_free_context(@ptrCast(&inCodecContext));

    // setup output parameters
    var outFmtContext: ?*c.AVFormatContext = null;
    try _check(c.avformat_alloc_output_context2(&outFmtContext, null, null, outputPath.ptr));
    defer c.avformat_free_context(outFmtContext);

    var codecId: c_uint = c.AV_CODEC_ID_VORBIS;
    if (std.mem.endsWith(u8, outputPath, ".wav")) {
        codecId = c.AV_CODEC_ID_PCM_S16LE;
    }

    const outCodec: *const c.AVCodec = try _nonnull(c.avcodec_find_encoder(codecId));
    const outStream: *c.AVStream = try _nonnull(c.avformat_new_stream(outFmtContext, outCodec));

    const outCodecContext: *c.AVCodecContext = try _nonnull(c.avcodec_alloc_context3(outCodec));
    outCodecContext.bit_rate = OUTPUT_BIT_RATE;
    outCodecContext.sample_rate = OUTPUT_SAMPLE_RATE;
    outCodecContext.sample_fmt = if (outCodec.sample_fmts) |fmts| fmts[0] else c.AV_SAMPLE_FMT_FLTP;
    try _check(c.av_channel_layout_copy(&outCodecContext.ch_layout, &c.AV_CHANNEL_LAYOUT_STEREO));
    outCodecContext.time_base = .{ .num = 1, .den = OUTPUT_SAMPLE_RATE };

    // open codec context now - we need its frame_size variable, which doesn't get populated until we actually open it
    try _check(c.avcodec_open2(outCodecContext, outCodec, null));

    // copy parameters from the codec context into the stream's parameters
    try _check(c.avcodec_parameters_from_context(outStream.codecpar, outCodecContext));

    // allocate a temporary frame to hold our resampled audio
    var tmpCvtFrame: *c.AVFrame = try _nonnull(c.av_frame_alloc());
    defer c.av_frame_free(@ptrCast(&tmpCvtFrame));
    tmpCvtFrame.format = outCodecContext.sample_fmt;
    tmpCvtFrame.sample_rate = outCodecContext.sample_rate;
    tmpCvtFrame.nb_samples = if (outCodec.capabilities & c.AV_CODEC_CAP_VARIABLE_FRAME_SIZE == 0) outCodecContext.frame_size else 1024;
    tmpCvtFrame.ch_layout = outCodecContext.ch_layout;
    try _check(c.av_frame_get_buffer(tmpCvtFrame, 0));

    var outPacket: *c.AVPacket = try _nonnull(c.av_packet_alloc());
    defer c.av_packet_free(@ptrCast(&outPacket));

    var swrContext = try swr_alloc(
        // src audio properties
        &inCodecContext.ch_layout, inCodecContext.sample_rate, inCodecContext.sample_fmt,
        // dst audio properties
        &outCodecContext.ch_layout, outCodecContext.sample_rate, outCodecContext.sample_fmt
    );
    defer c.swr_free(@ptrCast(&swrContext));

    try _check(c.avio_open(&outFmtContext.?.pb, outputPath.ptr, c.AVIO_FLAG_WRITE));
    try _check(c.avformat_write_header(outFmtContext, null));
    {
        // here's where we would read in from our current input av struct, and write out to the codec context
        var audioState: AvState = .{
            .packet = inAv.packet,
            .srcFrame = inAv.srcFrame,
            .cvtFrame = tmpCvtFrame,
            .fmtContext = inAv.fmtContext,
            .cvtContext = .{ .audio = swrContext },
            .index = inIdx,
            .codecContext = inCodecContext,
            .resend = false,
        };

        var writingOutput: bool = true;
        var encoderDone: bool = false;
        var inputDone: bool = false;
        var timestamp: i64 = 0;
        while (writingOutput) {
            if (!inputDone) {
                _ = decodeAndProcessFrame(&audioState) catch |err| {
                    if (err == error.EndOfFile) {
                        inputDone = true;
                    } else {
                        return err;
                    }
                };
            }

            // try to read any encoded output data; if we get anything, write it out
            while (true) {
                _check(c.avcodec_receive_packet(outCodecContext, outPacket)) catch |err| {
                    if (err == error.WouldBlock) {
                        break;
                    } if (err == error.EndOfFile) {
                        writingOutput = false;
                        break;
                    } else {
                        return err;
                    }
                };

                // i _think_ this is how we generate pts/dts? it's just the amount of samples sent so far
                outPacket.pts = timestamp;
                outPacket.dts = timestamp;

                try _check(c.av_interleaved_write_frame(outFmtContext, outPacket));

                timestamp += if (outPacket.duration != 0) outPacket.duration else outCodecContext.frame_size;
            }

            if (!encoderDone) {
                // we need to send a null/flushing frame eventually, but swresample has an issue where audio data can
                // still be leftover in the context's buffer, which means we need to drain swresample first and then
                // we can send our null/flush frame to the encoder to drain the encoder.
                var nullableCvtFrame: ?*c.AVFrame = audioState.cvtFrame;
                if (inputDone) {
                    if (c.swr_get_delay(swrContext, OUTPUT_SAMPLE_RATE) > audioState.cvtFrame.nb_samples) {
                        try _check(c.swr_convert_frame(swrContext, audioState.cvtFrame, null));
                    } else {
                        nullableCvtFrame = null;
                    }
                }

                // cvtFrame contains the resampled audio, feed it to the output codec context
                _check(c.avcodec_send_frame(outCodecContext, nullableCvtFrame)) catch |err| {
                    if (err == error.WouldBlock) {
                        continue;
                    } else if (err == error.EndOfFile) {
                        encoderDone = true;
                    } else {
                        return err;
                    }
                };
            }
        }
    }

    try _check(c.av_write_trailer(outFmtContext));

    // rewind back to the start
    try _check(c.avformat_seek_file(inAv.fmtContext, -1, std.math.minInt(i64), inAv.fmtContext.start_time, inAv.fmtContext.start_time, 0));
    return 1;
}


pub fn readFrame(self: *Self, ptsOut: *i64, skipLut: bool) !i32 {
    const av = &self.av.?;
    const pts = decodeAndProcessFrame(av) catch |err| {
        if (err == error.EndOfFile) {
            return 0;
        } else {
            return err;
        }
    };
    defer ptsOut.* = pts;

    if (skipLut) {
        return 1;
    }

    // pixel format is GBR!
    const gPlane = av.cvtFrame.data[0];
    const bPlane = av.cvtFrame.data[1];
    const rPlane = av.cvtFrame.data[2];

    const pixelDimensions = dimensionToPixel(self.dimensions).pixel;
    const linesize = @as(usize, @intCast(av.cvtFrame.linesize[0]));
    const limit = linesize * pixelDimensions.height;

    var widthIdx: usize = 0;

    var srcIdx: usize = 0;
    var dstIdx: usize = 0;
    // take advantage of the fact that limit will always be a multiple of 32 (because of libav alignment),
    // which is a multiple of 16. we don't have to do any additional "remaining" loop afterwards
    while (srcIdx + Lut.BlockLen <= limit) {
        // check if this would run out of bounds of the actual width - the next data might be just padding
        if (widthIdx + Lut.BlockLen > pixelDimensions.width) {
            // ... but we might actually be behind! the non-padded width might not be a multiple of 16.
            if (widthIdx < pixelDimensions.width) {
                const remaining = pixelDimensions.width - widthIdx;
                for (0..remaining) |r| {
                    const srIdx = srcIdx + r;
                    const drIdx = calculateOffset(self.dimensions, dstIdx + r);
                    self.buffer[drIdx] = Lut.gatherSingle(rPlane[srIdx], gPlane[srIdx], bPlane[srIdx]);
                }
                dstIdx += remaining;
            }

            const padding = linesize - widthIdx;
            srcIdx += padding;
            widthIdx = 0;
            if (srcIdx + Lut.BlockLen > limit) break;
        }

        const rSlice = rPlane[srcIdx..][0..Lut.BlockLen];
        const gSlice = gPlane[srcIdx..][0..Lut.BlockLen];
        const bSlice = bPlane[srcIdx..][0..Lut.BlockLen];
        const writeOffset = calculateOffset(self.dimensions, dstIdx);
        self.buffer[writeOffset..][0..Lut.BlockLen].* = Lut.gatherBlock(rSlice, gSlice, bSlice);

        srcIdx += Lut.BlockLen;
        dstIdx += Lut.BlockLen;
        widthIdx += Lut.BlockLen;
    }

    return 1;
}

pub fn adjustOutput(self: *Self, newDimensions: Dimensions) !void {
    // convert dimensions to pixels if they're expressed in minecraft maps (just like in open())
    const size = dimensionToPixel(newDimensions).pixel;

    // construct a new frame temporarily, so if this function fails, it doesn't mess with the existing state
    var newCvtFrame = try _nonnull(c.av_frame_alloc());
    errdefer c.av_frame_free(@ptrCast(&newCvtFrame));

    // reallocate the data backing cvtFrame
    newCvtFrame.width = @intCast(size.width);
    newCvtFrame.height = @intCast(size.height);
    newCvtFrame.format = c.AV_PIX_FMT_GBRP;
    try _check(c.av_frame_get_buffer(newCvtFrame, 0));

    const av = &self.av.?;
    const newSwsContext = try sws_alloc_multithread(
        // src frame properties
        av.codecContext.width, av.codecContext.height, av.codecContext.pix_fmt,
        // dst frame properties
        @intCast(size.width), @intCast(size.height), c.AV_PIX_FMT_GBRP,
    );
    errdefer c.sws_free_context(&newSwsContext);

    // everything is fine - free our old stuff in AvState
    c.av_frame_free(@ptrCast(&av.cvtFrame));
    c.sws_free_context(@ptrCast(&av.cvtContext.video));

    // and update to point to our new targets
    av.cvtFrame = newCvtFrame;
    av.cvtContext = .{ .video = newSwsContext };
    self.dimensions = newDimensions;
}

pub fn free(self: *Self) void {
    const av = &self.av.?;
    c.sws_free_context(@ptrCast(&av.cvtContext.video));
    c.avcodec_free_context(@ptrCast(&av.codecContext));
    c.av_frame_free(@ptrCast(&av.cvtFrame));
    c.av_frame_free(@ptrCast(&av.srcFrame));
    c.av_packet_free(@ptrCast(&av.packet));
    c.avformat_close_input(@ptrCast(&av.fmtContext));
}

fn decodeAndProcessFrame(av: *AvState) !i64 {
    const pts = try internalDecodeFrame(av);
    if (pts != 0) {
        switch (av.cvtContext) {
            .audio => |swrContext| {
                try _check(c.swr_convert_frame(swrContext, av.cvtFrame, av.srcFrame));
            },
            .video => |swsContext| {
                try _check(c.sws_scale_frame(swsContext, av.cvtFrame, av.srcFrame));
            }
        }
    }
    return pts;
}

fn internalDecodeFrame(av: *AvState) !i64 {
    while (true) {
        var haveFrame: bool = true;
        _check(c.avcodec_receive_frame(av.codecContext, av.srcFrame)) catch |err| {
            if (err == error.WouldBlock) {
                // ran out of frames to return to the user - have to queue some more!
                haveFrame = false;
            } else if (err == error.InvalidData) {
                continue;
            } else {
                return err;
            }
        };

        // decoded a frame - break out so we can return it back to the user
        if (haveFrame) {
            break;
        }

        var flushing = false;
        while (true) {
            if (!av.resend) {
                // didn't have a frame ready - keep feeding data to the codec context until it's full or done
                _check(c.av_read_frame(av.fmtContext, av.packet)) catch |err| {
                    // docs state "On error, pkt will be blank." which is perfect since if its blank, then it tells the
                    // codec to flush
                    // "It can be NULL (or an AVPacket with data set to NULL and size set to 0); in this case, it is
                    // considered a flush packet, which signals the end of the stream".
                    if (err == error.EndOfFile) {
                        flushing = true;
                    } else {
                        return err;
                    }
                };
            }

            // only send packet if it's a flush packet or is from our stream
            if (flushing or av.packet.stream_index == av.index) {
                // we have the correct data - feed it to the decoder
                _check(c.avcodec_send_packet(av.codecContext, av.packet)) catch |err| {
                    if (err == error.WouldBlock) {
                        av.resend = true;
                        break;
                    } else if (err == error.InvalidData) {
                        // skip invalid data; it happens sometimes...
                        continue;
                    } else {
                        return err;
                    }
                };
                av.resend = false;
            }
        }
    }

    return av.srcFrame.pts;
}

fn findBestStream(fmtContext: *c.AVFormatContext, streamType: i32) !?struct { usize, *const c.AVCodec, *c.AVCodecContext} {
    var codec: ?*const c.AVCodec = null;
    const index = c.av_find_best_stream(fmtContext, streamType, -1, -1, &codec, 0);
    _check(index) catch |err| {
        if (err == AvError.StreamNotFound) {
            return null;
        } else {
            return err;
        }
    };
    const codecContext = try _nonnull(c.avcodec_alloc_context3(codec));
    return .{ @intCast(index), codec.?, codecContext };
}

// implemented from https://aras-p.info/blog/2024/02/06/I-accidentally-Blender-VSE/ thank you!
// was losing my mind trying to figure out to get sws_scale to be multithreaded all those years ago...
fn sws_alloc_multithread(srcW: c_int, srcH: c_int, srcFormat: c.AVPixelFormat,
                         dstW: c_int, dstH: c_int, dstFormat: c.AVPixelFormat) !*c.SwsContext {
    var ctx = try _nonnull(c.sws_alloc_context());
    errdefer c.sws_free_context(@ptrCast(&ctx));

    try _check(c.av_opt_set_int(ctx, "srcw", srcW, 0));
    try _check(c.av_opt_set_int(ctx, "srch", srcH, 0));
    try _check(c.av_opt_set_int(ctx, "src_format", srcFormat, 0));
    try _check(c.av_opt_set_int(ctx, "dstw", dstW, 0));
    try _check(c.av_opt_set_int(ctx, "dsth", dstH, 0));
    try _check(c.av_opt_set_int(ctx, "dst_format", dstFormat, 0));
    try _check(c.av_opt_set_int(ctx, "sws_flags", c.SWS_FAST_BILINEAR, 0));
    try _check(c.av_opt_set_int(ctx, "threads", 0, 0)); // enables auto multithreading

    try _check(c.sws_init_context(ctx, null, null));
    return ctx;
}

fn swr_alloc(srcChannelLayout: *c.AVChannelLayout, srcSampleRate: c_int, srcSampleFmt: c_int,
             dstChannelLayout: *c.AVChannelLayout, dstSampleRate: c_int, dstSampleFmt: c_int) !*c.SwrContext {
    var ctx = c.swr_alloc().?;
    errdefer c.swr_free(@ptrCast(&ctx));

    try _check(c.av_opt_set_chlayout(ctx, "in_chlayout", srcChannelLayout, 0));
    try _check(c.av_opt_set_int(ctx, "in_sample_rate", srcSampleRate, 0));
    try _check(c.av_opt_set_sample_fmt(ctx, "in_sample_fmt", srcSampleFmt, 0));
    try _check(c.av_opt_set_chlayout(ctx, "out_chlayout", dstChannelLayout, 0));
    try _check(c.av_opt_set_int(ctx, "out_sample_rate", dstSampleRate, 0));
    try _check(c.av_opt_set_sample_fmt(ctx, "out_sample_fmt", dstSampleFmt, 0));

    try _check(c.swr_init(ctx));
    return ctx;
}

fn dimensionToPixel(d: Dimensions) Dimensions {
    return switch(d) {
        .pixel => d,
        .map => |m| .{ .pixel = .{ .width = m.width * 128, .height = m.height * 128, } },
    };
}

fn calculateOffset(d: Dimensions, idx: usize) usize {
    switch (d) {
        .pixel => return idx,
        .map => |m| {
            const rowLength = m.width * 128;
            const y = idx / rowLength;
            const x = idx % rowLength;

            const mapY = y / 128;
            const mapX = x / 128;

            // it feels like we could do better than this messy math
            const mapOffset = (mapY * m.width + mapX) * 128 * 128;
            return mapOffset + ((y % 128) * 128) + (x % 128);
        },
    }
}

fn _nonnull(val: anytype) !_cPtrToZigPtr(@TypeOf(val)) {
    if (val == null) return error.OutOfMemory;
    return val;
}

fn _cPtrToZigPtr(val: type) type {
    const ptrInfo = @typeInfo(val).pointer;
    const t = @Pointer(.one, .{
        .@"addrspace" = ptrInfo.address_space,
        .@"align" = ptrInfo.alignment,
        .@"allowzero" = false,
        .@"const" = ptrInfo.is_const,
        .@"volatile" = ptrInfo.is_volatile,
    }, ptrInfo.child, null);
    return t;
}

fn _check(status: c_int) (PosixError || AvError)!void {
    // successful; just return since ffmpeg normally states that >=0 is a success
    if (status >= 0) return;

    const p = std.posix.E;

    // try to interpret it as an AVERROR value first
    return switch(status) {
        c.AVERROR_BSF_NOT_FOUND => AvError.BitstreamFilterNotFound,
        c.AVERROR_BUG => AvError.Bug,
        c.AVERROR_BUFFER_TOO_SMALL => AvError.BufferTooSmall,
        c.AVERROR_DECODER_NOT_FOUND => AvError.DecoderNotFound,
        c.AVERROR_DEMUXER_NOT_FOUND => AvError.DemuxerNotFound,
        c.AVERROR_ENCODER_NOT_FOUND => AvError.EncoderNotFound,
        c.AVERROR_EOF => AvError.EndOfFile,
        c.AVERROR_EXIT => AvError.Exit,
        c.AVERROR_EXTERNAL => AvError.External,
        c.AVERROR_FILTER_NOT_FOUND => AvError.FilterNotFound,
        c.AVERROR_INVALIDDATA => AvError.InvalidData,
        c.AVERROR_MUXER_NOT_FOUND => AvError.MuxerNotFound,
        c.AVERROR_OPTION_NOT_FOUND => AvError.OptionNotFound,
        c.AVERROR_PATCHWELCOME => AvError.PatchWelcome,
        c.AVERROR_PROTOCOL_NOT_FOUND => AvError.ProtocolNotFound,
        c.AVERROR_STREAM_NOT_FOUND => AvError.StreamNotFound,
        c.AVERROR_BUG2 => AvError.Bug2,
        c.AVERROR_UNKNOWN => AvError.Unknown,
        c.AVERROR_EXPERIMENTAL => AvError.Experimental,

        -@as(c_int, @intFromEnum(p.INVAL)) => PosixError.Invalid,
        -@as(c_int, @intFromEnum(p.NOENT)) => PosixError.FileNotFound,
        -@as(c_int, @intFromEnum(p.NOMEM)) => PosixError.OutOfMemory,
        -@as(c_int, @intFromEnum(p.PERM)) => PosixError.PermissionDenied,
        -@as(c_int, @intFromEnum(p.AGAIN)) => PosixError.WouldBlock,
        -@as(c_int, @intFromEnum(p.RANGE)) => PosixError.OutOfRange,

        else => AvError.Unexpected,
    };
}

const AvError = error {
    BitstreamFilterNotFound,
    Bug,
    BufferTooSmall,
    DecoderNotFound,
    DemuxerNotFound,
    EncoderNotFound,
    EndOfFile,
    Exit,
    External,
    FilterNotFound,
    InvalidData,
    MuxerNotFound,
    OptionNotFound,
    PatchWelcome,
    ProtocolNotFound,
    StreamNotFound,
    Bug2,
    Unknown,
    Experimental,
    Unexpected,
};

const PosixError = error {
    Invalid,
    FileNotFound,
    OutOfMemory,
    PermissionDenied,
    WouldBlock,
    OutOfRange
};