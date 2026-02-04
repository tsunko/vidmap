//nativemap_global_init   ([*c]u8)                            bool        false = failed to load lut, true = otherwise
//nativemap_alloc_context (short w, short h)                  *Context    nullptr = failed to alloc context, ptr otherwise
//nativemap_open_input    (*Context, [*c]u8, [*c]f64)         int         <0 = error, >=0 = success, writes timescale to double ptr
//nativemap_read_frame    (*Context, [*c]long)                int         <0 = error, 0 = end of stream, >0 = success, also write pts to long ptr
//nativemap_adjust_output (*Context, short w, short h)        int         <0 = error, >=0 = success
//nativemap_free_context  (*Context)                          void        nothing

const std = @import("std");
const Lut = @import("Lut.zig");
const Context = @import("Context.zig");

const assert = std.debug.assert;
const alloc = std.heap.c_allocator;

export fn nativemap_global_init(lutPath: ?[*:0]const u8) bool {
    Lut.loadTable(std.mem.span(lutPath.?), std.Io.Threaded.global_single_threaded.io(), alloc) catch |err| {
        std.log.err("Failed to load LUT table: {s}", .{ @errorName(err) });
        return false;
    };
    return true;
}

export fn nativemap_alloc_context(mapWidth: c_short, mapHeight: c_short) ?*Context {
    assert(mapWidth > 0 and mapHeight > 0);

    const dimensions = Context.Dimensions { .map = .{ .width = @intCast(mapWidth), .height = @intCast(mapHeight) } };
    const ctx = alloc.create(Context) catch return null;
    const buffer = alloc.alignedAlloc(u8, .fromByteUnits(64), dimensions.size()) catch {
        alloc.destroy(ctx);
        return null;
    };

    ctx.* = .{
        .buffer = buffer,
        .dimensions = dimensions,
        .av = null,
    };

    return ctx;
}

export fn nativemap_get_buffer(ctx: ?*Context) [*]const u8 {
    return ctx.?.buffer.ptr;
}

export fn nativemap_open_input(ctx: ?*Context, src: ?[*:0]u8, timescaleOut: ?*f64) c_int {
    timescaleOut.?.* = ctx.?.open(std.mem.span(src.?)) catch |err| {
        std.log.err("Failed to open input: {s}", .{ @errorName(err) });
        return -@as(c_int, @intCast(@intFromError(err)));
    };
    return 1;
}

export fn nativemap_read_frame(ctx: ?*Context, ptsOut: ?*c_long) c_int {
    return ctx.?.readFrame(ptsOut.?, false) catch |err| {
        std.log.err("Failed to read frame: {s}", .{ @errorName(err) });
        return -@as(c_int, @intCast(@intFromError(err)));
    };
}

export fn nativemap_adjust_output(ctx: ?*Context, newMapWidth: c_short, newMapHeight: c_short) c_int {
    const newDimensions = Context.Dimensions { .map = .{ .width = @intCast(newMapWidth), .height = @intCast(newMapHeight) } };
    const newBuffer = alloc.alignedAlloc(u8, .fromByteUnits(64), newDimensions.size()) catch {
        std.log.err("Failed to allocate memory for a new buffer!", .{});
        return -1;
    };

    ctx.?.adjustOutput(newDimensions) catch |err| {
        std.log.err("Failed to adjust output: {s}", .{ @errorName(err) });
        alloc.free(newBuffer);
        return -@as(c_int, @intCast(@intFromError(err)));
    };

    alloc.free(ctx.?.buffer);
    ctx.?.buffer = newBuffer;
    ctx.?.dimensions = newDimensions;
    return 1;
}

export fn nativemap_free_context(ctx: ?*Context) void {
    ctx.?.free();
    alloc.destroy(ctx.?);
}