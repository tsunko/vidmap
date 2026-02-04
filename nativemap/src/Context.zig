const std = @import("std");
const ztracy = @import("ztracy");
const c = @cImport({
    // we do this also in sdl_viewer.zig...
    @cDefine("__builtin_va_arg_pack", "((void (*)())(0))");
    @cInclude("libavcodec/avcodec.h");
    @cInclude("libavformat/avformat.h");
    @cInclude("libswscale/swscale.h");
    @cInclude("libavutil/imgutils.h");
    @cInclude("libavutil/opt.h");
    @cDefine("MKTAG(a,b,c,d)", "(((unsigned)a) | ((unsigned)(b) << 8) | ((unsigned)(c) << 16) | ((unsigned)(d) << 24))");
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
    packet: *c.AVPacket,
    srcFrame: *c.AVFrame,
    swsFrame: *c.AVFrame,

    fmtContext: *c.AVFormatContext,
    swsContext: *c.SwsContext,

    index: usize,
    codec: *const c.AVCodec,
    codecContext: *c.AVCodecContext,
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
    var packet = try _nonnull(c.av_packet_alloc());
    errdefer c.av_packet_free(&packet);

    var srcFrame = try _nonnull(c.av_frame_alloc());
    errdefer c.av_frame_free(&srcFrame);

    var swsFrame = try _nonnull(c.av_frame_alloc());
    errdefer c.av_frame_free(&swsFrame);

    // if we're expressing size in maps, convert it to pixels
    const size = dimensionToPixel(self.dimensions).pixel;

    // initialize the frame we use with sws_scale
    swsFrame.*.width = @intCast(size.width);
    swsFrame.*.height = @intCast(size.height);
    swsFrame.*.format = c.AV_PIX_FMT_GBRP;
    try _check(c.av_frame_get_buffer(swsFrame, 0));

    // initialize the video codec context and prepare it for decoding video streams
    var codec: ?*const c.AVCodec = null;
    const index: usize = @intCast(try _check(c.av_find_best_stream(fmtContext, c.AVMEDIA_TYPE_VIDEO, -1, -1, &codec, 0)));
    var codecContext = try _nonnull(c.avcodec_alloc_context3(codec));
    errdefer c.avcodec_free_context(&codecContext);

    // copy parameters so we decode this properly
    try _check(c.avcodec_parameters_to_context(codecContext, fmtContext.?.streams[index].*.codecpar));

    // set decoder to use multithreading when applicable, and to decode multiple slices of a single frame at once
    codecContext.*.thread_count = 0;
    codecContext.*.thread_type = c.FF_THREAD_SLICE;

    // open the codec for operation
    try _check(c.avcodec_open2(codecContext, codec, null));

    // initialize sws_scale for scaling the input video frames into the correct size and pixel format
    var swsContext = try sws_alloc_multithread(
        // src frame properties
        codecContext.*.width, codecContext.*.height, codecContext.*.pix_fmt,
        // dst frame properties
        @intCast(size.width), @intCast(size.height), c.AV_PIX_FMT_GBRP,
    );

    errdefer c.sws_free_context(&swsContext);

    self.av = .{
        .packet = packet,
        .srcFrame = srcFrame,
        .swsFrame = swsFrame,
        .fmtContext = fmtContext.?,
        .swsContext = swsContext,
        .index = index,
        .codec = codec.?,
        .codecContext = codecContext,
    };
    return c.av_q2d(fmtContext.?.streams[index].*.time_base);
}

pub fn readFrame(self: *Self, ptsOut: *i64, skipLut: bool) !i32 {
    const av = &self.av.?;
    const pts = try decodeAndProcessFrame(av);

    if (skipLut or pts == 0) {
        return 1;
    }

    // pixel format is GBR!
    const gPlane = av.swsFrame.data[0];
    const bPlane = av.swsFrame.data[1];
    const rPlane = av.swsFrame.data[2];

    const pixelDimensions = dimensionToPixel(self.dimensions).pixel;
    const linesize = @as(usize, @intCast(av.swsFrame.linesize[0]));
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

    ptsOut.* = pts;
    return 1;
}

pub fn adjustOutput(self: *Self, newDimensions: Dimensions) !void {
    // convert dimensions to pixels if they're expressed in minecraft maps (just like in open())
    const size = dimensionToPixel(newDimensions).pixel;

    // construct a new frame temporarily, so if this function fails, it doesn't mess with the existing state
    var newSwsFrame = try _nonnull(c.av_frame_alloc());
    errdefer c.av_frame_free(&newSwsFrame);

    // reallocate the data backing swsFrame
    newSwsFrame.*.width = @intCast(size.width);
    newSwsFrame.*.height = @intCast(size.height);
    newSwsFrame.*.format = c.AV_PIX_FMT_GBRP;
    try _check(c.av_frame_get_buffer(newSwsFrame, 0));

    const av = &self.av.?;
    const newSwsContext = try sws_alloc_multithread(
        // src frame properties
        av.codecContext.width, av.codecContext.height, av.codecContext.pix_fmt,
        // dst frame properties
        @intCast(size.width), @intCast(size.height), c.AV_PIX_FMT_GBRP,
    );
    errdefer c.sws_free_context(&newSwsContext);

    // everything is fine - free our old stuff in AvState
    c.av_frame_free(@ptrCast(&av.swsFrame));
    c.sws_free_context(@ptrCast(&av.swsContext));

    // and update to point to our new targets
    av.swsFrame = newSwsFrame;
    av.swsContext = newSwsContext;
    self.dimensions = newDimensions;
}

pub fn free(self: *Self) void {
    const av = &self.av.?;
    c.sws_free_context(@ptrCast(&av.swsContext));
    c.avcodec_free_context(@ptrCast(&av.codecContext));
    c.av_frame_free(@ptrCast(&av.swsFrame));
    c.av_frame_free(@ptrCast(&av.srcFrame));
    c.av_packet_free(@ptrCast(&av.packet));
    c.avformat_close_input(@ptrCast(&av.fmtContext));
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

        // TODO: REIMPLEMENT THE FLUSHING BECAUSE I WAS DEBUGGING SWS_SCALE AND WENT TOO FAR
        // didn't have a frame ready - keep feeding data to the codec context until it's full or done
        _check(c.av_read_frame(av.fmtContext, av.packet)) catch |err| {
            // docs state "On error, pkt will be blank." which is perfect since if its blank, then it tells the
            // codec to flush
            // "It can be NULL (or an AVPacket with data set to NULL and size set to 0); in this case, it is
            // considered a flush packet, which signals the end of the stream".
            if (err == error.EndOfFile) {
                return 0;
            } else {
                return err;
            }
        };
        defer c.av_packet_unref(av.packet);

        // only send packet if it's a flush packet or is from our video stream
        if (av.packet.stream_index != av.index) continue;

        // we have the correct video data - feed it to the decoder
        _check(c.avcodec_send_packet(av.codecContext, av.packet)) catch |err| {
            if (err == error.WouldBlock or err == error.InvalidData) {
                continue;
            } else {
                return err;
            }
        };
    }

    return av.srcFrame.pts;
}

fn decodeAndProcessFrame(av: *AvState) !i64 {
    const pts = try internalDecodeFrame(av);
    if (pts != 0) {
        try _check(c.sws_scale_frame(av.swsContext, av.swsFrame, av.srcFrame));
    }
    return pts;
}

// implemented from https://aras-p.info/blog/2024/02/06/I-accidentally-Blender-VSE/ thank you!
// was losing my mind trying to figure out to get sws_scale to be multithreaded all those years ago...
fn sws_alloc_multithread(srcW: c_int, srcH: c_int, srcFormat: c.AVPixelFormat,
    dstW: c_int, dstH: c_int, dstFormat: c.AVPixelFormat) !*c.SwsContext {
    var ctx = try _nonnull(c.sws_alloc_context());
    errdefer c.sws_free_context(&ctx);

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

fn _nonnull(val: anytype) !@TypeOf(val) {
    if (val == null) return error.OutOfMemory;
    return val;
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