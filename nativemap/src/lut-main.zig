const std = @import("std");
const color = @import("color.zig");

const LookupTableLen: usize = std.math.maxInt(u12) + 1;

pub fn main() anyerror!void {
    const stdout = std.io.getStdOut().writer();
    _ = try stdout.write("NativeMap LUT Generator\n");

    var generated: [LookupTableLen]u8 = undefined;
    std.mem.set(u8, generated[0..], 255);

    _ = try stdout.print("Target LUT Size: {d} bytes\n", .{LookupTableLen});

    var pixel: u16 = 0;
    while (pixel < LookupTableLen) : (pixel += 1) {
        if (generated[pixel] == 255) {
            const matched = color.slowMatchColor(pixel);
            generated[pixel] = matched;
        }
    }

    _ = try stdout.print("Filled LUT table - verifying...\n", .{});
    for (generated) |val| {
        if (val == 255) {
            var buf: [128]u8 = undefined;
            _ = try std.fmt.bufPrint(buf[0..], "Invalid color matched for {d}", .{val});
            try std.fs.cwd().writeFile("lut-bad.dat", generated[0..]);
            @panic(buf[0..]);
        }
    }

    try std.fs.cwd().writeFile("lut.dat", generated[0..]);
    _ = try stdout.print("Wrote file to {s}\\lut.dat.\nPlace this inside \"<nativemap path>/src/\".\n", .{getPath(std.fs.cwd())});
    _ = try stdout.print("Press ENTER to exit.\n", .{});

    var throwaway: [1]u8 = undefined;
    _ = try std.io.getStdIn().read(throwaway[0..]);
}

fn getPath(dir: std.fs.Dir) ![]u8 {
    return try dir.realpathAlloc(std.heap.page_allocator, "");
}
