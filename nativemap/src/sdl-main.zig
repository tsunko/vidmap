const std = @import("std");
const framebyframe = @import("frame-by-frame.zig");
const sdlv = @import("sdl-viewer.zig");
const mc = @import("mc.zig");
const ogg = @import("ogg-extract.zig");
const avcommon = @import("av-common.zig");
const color = @import("color.zig");
const tracy = @import("tracy.zig");

const c = @cImport({
    @cInclude("SDL.h");
});

var timer: c.SDL_TimerID = 0;
var frameDelay: u32 = 0;
var running: bool = true;

const SDLFrameByFrame = framebyframe.FrameByFrame(*sdlv.SDLViewer);

// 8K resolution - used to testing under extreme circumstances and forcing bottleneck onto CPU execution
const width = 7680;
const height = 4320;

const WANT_COLOR_TRANSLATION = true;

// just as a fore-warning:
// it's difficult to compare the SDL player's performance to in-game performance due to how SDL has to handle
// drawing to surface and whatnot. the SDL player will likely be slightly slower because of blitting.
pub fn main() anyerror!void {
    const stdout = std.io.getStdOut().writer();
    const allocator = std.testing.allocator;
    var iter = std.process.args();
    allocator.free(iter.next(allocator).? catch @panic("no arg[0]?"));
    const fileTarget: [:0]const u8 = try iter.next(allocator) orelse "video.mp4"[0..];

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
    while (running and !viewer.checkEvents()) {
        c.SDL_Delay(frameDelay);
    }

    _ = c.SDL_RemoveTimer(timer);
    fbf.free();
    viewer.exit();
    std.os.exit(0);
}

fn translateAndPass(data: [*c]const u8, viewer: *sdlv.SDLViewer) void {
    const len = width * height;
    const hack = @ptrCast([*]const u16, @alignCast(@alignOf(u16), data))[0..len];
    const realHack = @intToPtr([*]u16, @ptrToInt(&hack[0]))[0..len];

    if (WANT_COLOR_TRANSLATION) {
        const tracy_color_translate = tracy.ZoneN(@src(), "ColorTranslation");
        {
            const _UNROLL_LIM = 16;

            // do a partial loop unroll, since we see significant speed ups
            // ~34ms down to ~20ms on extreme resolutions
            var index: usize = 0;
            while (index < len) : (index += _UNROLL_LIM) {
                comptime var _unroll_index: usize = 0;
                inline while (_unroll_index < _UNROLL_LIM) : (_unroll_index += 1) {
                    const i = index + _unroll_index;
                    realHack[i] = color.toU16RGB(mc.ColorLookupTable[realHack[i]]);
                }
            }
        }
        tracy_color_translate.End();
    }

    const tracy_present = tracy.ZoneN(@src(), "SDL2");
    viewer.*.drawFrameCallback(data);
    tracy_present.End();

    tracy.FrameMark();
}

fn stepFrameCallback(interval: u32, fbfPtr: ?*c_void) callconv(.C) u32 {
    _ = interval;
    const fbf = @ptrCast(*SDLFrameByFrame, @alignCast(8, fbfPtr.?));

    const tracy_stepNextFrame = tracy.ZoneN(@src(), "stepNextFrame");
    if (!fbf.*.stepNextFrame()) {
        std.debug.print("No more frames - terminating.", .{});
        _ = @cmpxchgStrong(bool, &running, true, false, .Monotonic, .Monotonic);
        return 0;
    }
    tracy_stepNextFrame.End();
    return frameDelay;
}

fn strideMatch(stride: []u16) void {
    for (stride) |*pixel| {
        const matched = mc.ColorLookupTable[pixel.*];
        pixel.* = color.toU16RGB(matched);
    }
}
