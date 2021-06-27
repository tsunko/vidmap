const std = @import("std");
const framebyframe = @import("frame-by-frame.zig");
const sdlv = @import("sdl-viewer.zig");
const mc = @import("mc.zig");
const ogg = @import("ogg-extract.zig");
const avcommon = @import("av-common.zig");
const color = @import("color.zig");

const c = @cImport({
    @cInclude("SDL.h");
});

var timer: c.SDL_TimerID = 0;
var frameDelay: u32 = 0;

const SDLFrameByFrame = framebyframe.FrameByFrame(*sdlv.SDLViewer);
const width = 1280;
const height = 720;

pub fn main() anyerror!void {
    const stdout = std.io.getStdOut().writer();
    const stderr = std.io.getStdErr().writer();

    const allocator = std.testing.allocator;
    var iter = std.process.args();
    allocator.free(iter.next(allocator).? catch @panic("no arg[0]?"));
    const fileTarget: [:0]u8 = iter.next(allocator).? catch {
        _ = try stderr.write("Missing target file argument.\n");
        return;
    };

    _ = try stdout.print("Initializing SDL and AVCodec\n", .{});
    sdlv.initSDL();
    avcommon.initAVCodec();

    try ogg.findAndConvertAudio(fileTarget, "test.ogg");

    _ = try stdout.print("Creating SDL viewer and FrameByFrame\n", .{});
    var viewer = sdlv.createViewer();
    var fbf: SDLFrameByFrame = .{};

    _ = try stdout.print("Setting up FrameByFrame with target file being {s} and dimensions {d}x{d}\n", .{ fileTarget, width, height });
    frameDelay = @floatToInt(u32, try fbf.setup(fileTarget, width, height));
    _ = try stdout.print("Received frame delay of {d}ms\n", .{frameDelay});

    _ = try stdout.print("Initializing SDL with dimensions {d}x{d}\n", .{ width, height });
    try viewer.setup(width, height);

    _ = try stdout.print("Setting user data and callback\n", .{});
    fbf.userData = &viewer;
    fbf.callback = translateAndPass;

    _ = try stdout.print("Initializing SDL timer with delay of {d}ms\n", .{frameDelay});
    timer = c.SDL_AddTimer(frameDelay, stepFrameCallback, &fbf);

    _ = try stdout.print("Rendering now!\n", .{});
    while (!viewer.checkEvents()) {
        c.SDL_Delay(frameDelay);
    }

    viewer.freeSDLViewer();
    fbf.free();
}

fn translateAndPass(data: [*]const u8, viewer: *sdlv.SDLViewer) void {
    const len = width * height;
    const hack = @ptrCast([*]const u16, @alignCast(@alignOf(u16), data))[0..len];
    const realHack = @intToPtr([*]u16, @ptrToInt(&hack[0]))[0..len];

    for (realHack) |*pixel| {
        const matched = mc.ColorLookupTable[pixel.*];
        pixel.* = color.toU16RGB(matched);
    }

    viewer.*.drawFrameCallback(data);
}

fn stepFrameCallback(interval: u32, fbfPtr: ?*c_void) callconv(.C) u32 {
    const a = @ptrCast(*SDLFrameByFrame, @alignCast(8, fbfPtr.?));
    if (!a.*.stepNextFrame()) {
        return 0;
    }
    return frameDelay;
}
