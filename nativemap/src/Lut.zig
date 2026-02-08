const std = @import("std");
const assert = std.debug.assert;

const TableAlignment = 64;
var table: ?[]const u8 = null;

const SimdLen = std.simd.suggestVectorLength(u32);
pub const BlockLen = SimdLen orelse 8;

const U32Vec = @Vector(BlockLen, u32);
const ResultVec = @Vector(BlockLen, u8);
const IndexesVec = @Vector(BlockLen, i32);

const builtin = @import("builtin");
const haveAVX512F = builtin.cpu.has(.x86, .avx512f);
const haveAVX2 = builtin.cpu.has(.x86, .avx2);

/// Loads a color lookup table from the specified source file, allocating memory using the given allocator.
/// Internally, the loaded table does not represent the contents of the file. To support AVX, padding is added.
pub fn loadTable(src: []const u8, io: std.Io, alloc: std.mem.Allocator) !void {
    const handle = try std.Io.Dir.openFile(.cwd(), io, src, .{});
    defer handle.close(io);

    const loadedTable = try alloc.alloc(u8, try handle.length(io) + 4);
    @memset(loadedTable, 0xFF);

    _ = try std.Io.Dir.readFile(.cwd(), io, src, loadedTable);

    table = loadedTable;
}

/// Looks up a block of RGB values and returns a vector of indexes into the relevant color palette.
/// The size of each block is equal to `Lut.BlockLen`. On AVX512/AVX2 enabled CPUs, this will be the result of the value
/// returned by `std.simd.suggestVectorLength(u32)`. On unsupported CPUs (or if the aforementioned value was null), the
/// value of `Lut.BlockLen` will be 8 and this function performs a simple scalar lookup.
/// NOTE: If it is determined that the CPU includes SIMD instructions but is _not_ AVX capable (i.e ARM), this function
/// will fail to compile, due to it trying to use `vpgatherdd`.
/// TODO: benchmark vpgatherdd vs simd pointer arithmetic vs scalar
/// TODO: once benchmarked, use .fast_gather to determine vpgatherdd vs simd pointers
pub fn gatherBlock(r: *const [BlockLen]u8, g: *const [BlockLen]u8, b: *const [BlockLen]u8) ResultVec {
    var intermediate: U32Vec = undefined;

    if (gatherSimdMaybe) |gatherSimd| {
        const rVec: U32Vec = mortonSimd(r[0..BlockLen].*);
        const gVec: U32Vec = mortonSimd(g[0..BlockLen].*);
        const bVec: U32Vec = mortonSimd(b[0..BlockLen].*);
        const indexes: @Vector(BlockLen, i32) = @bitCast((rVec << @splat(2)) | (gVec << @splat(1)) | bVec);
        intermediate = gatherSimd(indexes);
    } else {
        inline for (0..BlockLen) |i| {
            intermediate[i] = gatherSingle(r[i], g[i], b[i]);
        }
    }

    // sanity check to see if we somehow mapped to the invalid 4 extra bytes we pad at the end
    assert(!@reduce(.Or, intermediate == @as(U32Vec, @splat(0xFF))));
    // and finally truncate everything down to u8
    return @as(ResultVec, @truncate(intermediate));
}

/// Look up a single matching color based on the input RGB color.
pub fn gatherSingle(r: u8, g: u8, b: u8) u8 {
    return table.?[mortonSingle(r) << 2 | mortonSingle(g) << 1 | mortonSingle(b)];
}

const gatherSimdMaybe: ?fn(IndexesVec) U32Vec = switch (SimdLen orelse -1) {
    16 => gatherAVX512,
    8 => gatherAVX2,
    else => null
};

fn gatherAVX512(indexes: IndexesVec) U32Vec {
    var ret: U32Vec = undefined;
    var mask: u16 = 0xFFFF;
    asm volatile (
        \\ vpgatherdd (%[base], %[indexes], 1), %[result]{%[mask]}
        : [result] "=&v" (ret),
          [mask] "+&{k1}" (mask),
        : [base] "r" (table.?.ptr),
          [indexes] "v" (indexes),
        : .{ .memory = true }
    );
    return ret;
}

fn gatherAVX2(indexes: IndexesVec) U32Vec {
    var ret: U32Vec = undefined;
    var mask: @Vector(BlockLen, i32) = @splat(@as(i32, -1));
    asm volatile (
        \\ vpgatherdd %[mask], (%[base], %[indexes], 1), %[result]
        : [result] "=&x" (ret),
          [mask] "+&x" (mask),
        : [base] "r" (table.?.ptr),
          [indexes] "x" (indexes),
        : .{ .memory = true }
    );
    return ret;
}

fn mortonSimd(val: U32Vec) U32Vec {
    var ret = val >> @splat(2);
    ret &= @splat(0x0000003F);

    ret = (ret ^ (ret << @splat(16)));
    ret &= @splat(0xff0000ff);

    ret = (ret ^ (ret << @splat(8)));
    ret &= @splat(0x0300f00f);

    ret = (ret ^ (ret << @splat(4)));
    ret &= @splat(0x030c30c3);

    ret = (ret ^ (ret << @splat(2)));
    ret &= @splat(0x09249249);

    return ret;
}

const mortonSingle: fn(u32) u32 =
    if (std.Target.x86.featureSetHas(builtin.cpu.features, .bmi2))
        mortonSingleAsm
    else
        mortonSingleEmulated;

fn mortonSingleAsm(val: u32) u32 {
    const src: u32 = (val >> 2) & 0x3F;
    const mask: u32 = 0b0010_0100_1001_0010_01;
    return asm (
        \\ pdep %[mask], %[src], %[res]
        : [res] "=r" (-> u32),
        : [src] "r" (src),
          [mask] "r" (mask),
    );
}

// so about that whole "if you don't have bmi2, you'd probably hcf"...
// a server i tested this on didn't have bmi2, it didn't even have avx2...
fn mortonSingleEmulated(val: u32) u32 {
    var result: u32 = 0;
    var src: u32 = (val >> 2) & 0x3F;
    var mask: u32 = 0b0010_0100_1001_0010_01;
    var lowest: u32 = 0;

    while (mask != 0) : (mask ^= lowest){
        lowest = mask & -% mask;
        if (src & 1 != 0) {
            result |= lowest;
        }
        src >>= 1;
    }

    return result;
}