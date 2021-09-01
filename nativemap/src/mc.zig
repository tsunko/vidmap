const std = @import("std");
pub const ColorLookupTable: []const u8 align(32) = @embedFile("lut.dat");
pub const MapByteSize: usize = (128 * 128);

usingnamespace @import("threadpool");

const PartitionPool = ThreadPool(processMapPartition, null);
var coreCount: usize = undefined;
var pool: ?*PartitionPool = null;

pub const NativeMapContext = struct {
    buffer: [*]u8,
    mapWidth: u16,
    mapHeight: u16,
};

pub fn toMinecraftColors(frameData: [*c]const u8, contextNullable: ?*NativeMapContext) void {
    if (pool == null) {
        coreCount = std.Thread.getCpuCount() catch 1;
        pool = PartitionPool.init(std.heap.c_allocator, coreCount) catch {
            @panic("Failed to create color translation thread pool");
        };
    }

    const context = contextNullable.?;
    const len = context.mapWidth * context.mapHeight * MapByteSize;
    const dst = context.buffer[0..len];
    // do hacky pointer casting - note: we don't particularly care about endian yet
    // we handle endianness within mc.zig
    const casted = @ptrCast([*]const u16, @alignCast(@alignOf(u16), frameData))[0..len];

    // check if we're just doing a single map - if we are, no fancy partitioning
    // needed, otherwise, we need to do some math to figure out where to put stuff
    if (context.mapWidth | context.mapHeight == 1) {
        for (dst) |*out, index| {
            out.* = ColorLookupTable[casted[index]];
        }
    } else {
        // TODO: figure out how to do this with strides instead of 1 at a time
        // the performance benefit is highly likely to be negligible though, reason being: the point in which we'd
        // benefit from striding casted is the same point in which we're likely running into the brick wall of
        // minecraft's limitations - each map item takes up 128*128 bytes, which can result in >=100mb/s bandwidth
        // thoughput if we're doing 1080p _equivalent_ at 60fps (unlikely scenario, but within reason).
        // for now, ~720p @ 24-30fps is the sweet spot for not encountering it
        // hypothetically you could go ~1080p @ 30fps, but we'd be hoping the video hits cache a lot

        // disregard everything above - attempting to vectorize this isn't possible because of the fact that we use
        // a lookup table to figure out what color is what palette index. ideally we would be able to use VGATHERDPS
        // but this has the significant drawback of actually being worse in performance compared to scalar; it is
        // only better on skylake+ cpus and is just... bad on ryzen. we'd just need more raw IPC.

        // another avenue to explore is possible multi-threading our code, but as far as i remember, multithreading
        // on zig isn't exactly easy, nor does it provide exceptional performance improvements, at the cost of
        // having to rework the entire codebase to prevent race conditions, deadlocks, etc.
        const width = @intCast(usize, context.mapWidth);

        const step = len / coreCount;
        var index: usize = 0;
        while (index < len) : (index += step) {
            pool.?.submitTask(.{
                casted,
                dst,
                index,
                step,
                width,
            }) catch @panic("Failed to submit color translation task");
        }

        pool.?.awaitTermination() catch |err| {
            if (err == error.Forced) {
                return;
            } else {
                @panic("awaitTermination error: not forced?");
            }
        };
    }
}

fn processMapPartition(src: []const u16, dst: []u8, start: usize, len: usize, width: usize) void {
    const linelength = width * 128;
    const _UNROLL_LIM = 16;

    // basically do the same partial loop unrolling seen in sdl-main.zig
    var srcIndex: usize = start;
    while (srcIndex < start + len) : (srcIndex += _UNROLL_LIM) {
        const y = srcIndex / linelength;
        const x = srcIndex % linelength;

        const mapY = y / 128;
        const mapX = x / 128;

        // it feels like we could do better than this messy math
        const mapOffset = (mapY * width + mapX) * MapByteSize;
        const dstIndex = mapOffset + ((y % 128) * 128) + (x % 128);

        comptime var _unroll_index: usize = 0;
        inline while (_unroll_index < _UNROLL_LIM) : (_unroll_index += 1) {
            const i = srcIndex + _unroll_index;
            const j = dstIndex + _unroll_index;

            dst[j] = ColorLookupTable[src[i]];
        }
    }
}
