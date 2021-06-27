const fbf = @import("frame-by-frame.zig");

pub const ColorLookupTable = @embedFile("lut.dat");
pub const MapByteSize: usize = (128 * 128);

pub const NativeMapContext = struct {
    buffer: [*]u8,
    mapWidth: u32,
    mapHeight: u32,
};

pub fn toMinecraftColors(frameData: [*]const u8, context: *NativeMapContext) void {
    const len = calcBufferSize(context);
    const dst = context.buffer[0..len];
    // do hacky pointer casting - note: we don't particularly care about endian yet
    // we handle endianness within mc.zig
    const casted = @ptrCast([*]const u16, @alignCast(@alignOf(u16), frameData))[0..len];

    // check if we're just doing a single map - if we are, no fancy partitioning
    // needed, otherwise, we need to do some math to figure out where to put stuff
    if (context.mapWidth * context.mapHeight == 1) {
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
        const width = context.mapWidth;
        const linelength = width * 128;

        for (casted) |data, index| {
            const y = index / linelength;
            const x = index % linelength;

            const mapY = y / 128;
            const mapX = x / 128;

            // it feels like we could do better than this messy math
            const mapOffset = (mapY * width + mapX) * MapByteSize;
            const dstOffset = mapOffset + ((y % 128) * 128) + (x % 128);
            dst[dstOffset] = ColorLookupTable[data];
        }
    }
}

fn calcBufferSize(context: *NativeMapContext) usize {
    return (context.mapWidth * context.mapHeight) * (128 * 128);
}
