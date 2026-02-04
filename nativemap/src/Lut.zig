const std = @import("std");
const assert = std.debug.assert;

// gather functions for mapping RGB -> Index
// Lut.gatherBlock   (r[], g[], b[])                     void
// Lut.gatherSingle  (r, g, b)                           void
//
// morton part generators:
// Lut.mortonSimd   (r[], g[], b[])
// Lut.mortonSingle (r, g, b)
//
// table shouldn't be pub
// how to handle mapWidth? trick question, we don't, do the loop logic in Context.

const TableAlignment = 64;
var table: ?[]const u8 = null;

const SimdLen = std.simd.suggestVectorLength(u32);
pub const BlockLen = SimdLen orelse 8;

const U32Vec = @Vector(BlockLen, u32);
const ResultVec = @Vector(BlockLen, u8);

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

    // this should compile down to the relevant branch since SimdLen is a constant at comptime
    switch (SimdLen orelse -1) {
        16, 8, -1 => |len| {
            // we supported some sort of SIMD instruction - try to use it!
            const rVec: U32Vec = mortonSimd(r[0..BlockLen].*);
            const gVec: U32Vec = mortonSimd(g[0..BlockLen].*);
            const bVec: U32Vec = mortonSimd(b[0..BlockLen].*);

            const indexes: @Vector(BlockLen, i32) = @bitCast((rVec << @splat(2)) | (gVec << @splat(1)) | bVec);

            if (len == 16 and haveAVX512F) {
                // AVX512
                var mask: u16 = 0xFFFF;
                asm volatile (
                    \\ vpgatherdd (%[base], %[indexes], 1), %[result]{%[mask]}
                    : [result] "=&v" (intermediate),
                      [mask] "+&{k1}" (mask),
                    : [base] "r" (table.?.ptr),
                      [indexes] "v" (indexes),
                    : .{ .memory = true }
                );
            } else if (len == 8 and haveAVX2 and builtin.zig_backend != .stage2_x86_64) {
                // this is apparently invalid; i have no idea what the actual correct operands are lappDumb
                var mask: @Vector(BlockLen, i32) = @splat(@as(i32, -1));
                asm volatile (
                    \\ vpgatherdd %[mask], (%[base], %[indexes], 1), %[result]
                    : [result] "=&x" (intermediate),
                      [mask] "+&x" (mask),
                    : [base] "r" (table.?.ptr),
                      [indexes] "x" (indexes),
                    : .{ .memory = true }
                );
            } else {
                // scalar
                inline for (0..BlockLen) |i| {
                    intermediate[i] = gatherSingle(r[i], g[i], b[i]);
                }
            }
        },
        else => @compileError(std.fmt.comptimePrint("unsupported vector length {d}", .{ SimdLen })),
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

// NOTE: not going to bother switching between pdep and standard masking; a processor that doesn't support BMI2 probably
// would halt and catch fire trying to put videos on a minecraft map.
fn mortonSingle(val: u32) u32 {
    const src: u32 = (val >> 2) & 0x3F;
    const mask: u32 = 0b0010_0100_1001_0010_01;
    return asm (
        \\ pdep %[mask], %[src], %[res]
        : [res] "=r" (-> u32),
        : [src] "r" (src),
          [mask] "r" (mask),
    );
}