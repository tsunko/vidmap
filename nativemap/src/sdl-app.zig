const std = @import("std");
const mc = @import("mc.zig");
const color = @import("color.zig");
const tracy = @import("tracy.zig");
const audio = @import("audio-extractor.zig");

const FrameProcessor = @import("frame-processor.zig").FrameProcessor;

usingnamespace @import("threadpool");
const sdl = @cImport({
    @cInclude("SDL.h");
});

// 8K resolution - used to testing under extreme circumstances and forcing bottleneck onto CPU execution
const WINDOW_WIDTH = 7680;
const WINDOW_HEIGHT = 4320;

const ColorTranslationPool = ThreadPool(translateColors, null);
const SDLFrameProcessor = FrameProcessor(*SDLWindow);

var running: bool = true;

const SDLWindow = struct {
    // the only two functions that you can set this without breaking is SDL_BlitSurface and SDL_BlitScaled
    // note: if you use SDL_BlitScaled, there is a _massive_ performance penalty, obviously due to scaling
    const BlitFunction = sdl.SDL_BlitSurface;
    const Self = @This();

    window: *sdl.SDL_Window,
    surface: *sdl.SDL_Surface,

    pub fn create(width: u16, height: u16) Self {
        return Self{
            .window = sdl.SDL_CreateWindow(
                "Vidmap MC Viewer",
                sdl.SDL_WINDOWPOS_CENTERED,
                sdl.SDL_WINDOWPOS_CENTERED,
                width,
                height,
                sdl.SDL_WINDOW_MAXIMIZED,
            ).?,
            .surface = makeSurface(width, height),
        };
    }

    pub fn updateWindow(self: *Self, data: [*]const u8) void {
        self.surface.*.pixels = @intToPtr([*]u8, @ptrToInt(data));

        // tracy start
        _ = BlitFunction(self.surface, null, sdl.SDL_GetWindowSurface(self.window), null);
        // tracy end

        _ = sdl.SDL_UpdateWindowSurface(self.window);
    }

    pub fn processInput(self: *Self) bool {
        _ = self;

        var event: sdl.SDL_Event = undefined;
        _ = sdl.SDL_PollEvent(&event);
        return event.@"type" != sdl.SDL_QUIT;
    }

    pub fn exit(self: *Self) void {
        _ = self;
        sdl.SDL_Quit();
    }

    fn makeSurface(width: u16, height: u16) *sdl.SDL_Surface {
        var surface = sdl.SDL_CreateRGBSurfaceWithFormat(0, 0, 0, 16, sdl.SDL_PIXELFORMAT_RGB444);
        surface.*.flags |= sdl.SDL_PREALLOC;
        surface.*.w = width;
        surface.*.h = height;
        surface.*.pitch = width * 2;
        return surface;
    }
};

const allocator = std.testing.allocator;
var threadPool: *ColorTranslationPool = undefined;

pub fn main() !void {
    const target = parseTarget(allocator);
    std.debug.print("Opening {s}\n", .{target});

    if (sdl.SDL_Init(sdl.SDL_INIT_VIDEO | sdl.SDL_INIT_TIMER) != 0) {
        @panic("Failed to init sdl.SDL");
    }

    try audio.extractAudio(target, "audio.ogg");

    var window = SDLWindow.create(WINDOW_WIDTH, WINDOW_HEIGHT);
    threadPool = try ColorTranslationPool.init(allocator, 4);
    var processor = try allocator.create(SDLFrameProcessor);
    processor.* = .{
        .userData = &window,
        .callback = updateSDLWindow,
    };

    const frameDelay = @floatToInt(u32, try processor.open(target, WINDOW_WIDTH, WINDOW_HEIGHT));
    const timer = sdl.SDL_AddTimer(frameDelay, stepNextFrame, processor);

    while (running and window.processInput()) {
        sdl.SDL_Delay(frameDelay);
    }

    _ = sdl.SDL_RemoveTimer(timer);
}

fn parseTarget(alloc: *std.mem.Allocator) [:0]const u8 {
    const default = "video.mp4"[0..];

    var argsIter = std.process.args();
    // skip own exe path
    _ = argsIter.skip();
    return (argsIter.next(alloc) orelse default) catch default;
}

fn translateColors(pixelData: [*]u16, srcOff: usize, len: usize) void {
    for (pixelData[srcOff .. srcOff + len]) |*pixel| {
        pixel.* = color.toU16RGB(mc.ColorLookupTable[pixel.*]);
    }
}

fn updateSDLWindow(rawData: [*c]const u8, window: ?*SDLWindow) void {
    const pixelCount = WINDOW_WIDTH * WINDOW_HEIGHT;
    // first we force zig to accept alignment, because right now it doesn't know it's already aligned
    const realigned = @ptrCast([*]const u16, @alignCast(@alignOf(u16), rawData))[0..pixelCount];
    // and then we do hacky stuff to interpret this as mutable RGBA4444 short data, since we actually
    // want to write back to this (as we have to display it via SDL_Surface)
    const pixelData = @intToPtr([*]u16, @ptrToInt(&realigned[0]))[0..pixelCount];

    const tracy_colorTranslate = tracy.ZoneN(@src(), "Color Translation");
    // figure out how big each workload should be
    const partition = (pixelCount * @sizeOf(u16)) / ((std.Thread.getCpuCount() catch 2) / 2);
    var index: usize = 0;
    while (index < pixelCount) : (index += partition) {
        threadPool.submitTask(.{
            pixelData,
            index,
            partition,
        }) catch @panic("Failed to submit color translation task");
    }
    threadPool.awaitTermination() catch return;
    tracy_colorTranslate.End();

    const tracy_updateWindow = tracy.ZoneN(@src(), "Update SDL Window");
    window.?.updateWindow(rawData);
    tracy_updateWindow.End();
}

fn stepNextFrame(interval: u32, processorPtr: ?*c_void) callconv(.C) u32 {
    defer tracy.FrameMark();

    var processor = @ptrCast(*SDLFrameProcessor, @alignCast(8, processorPtr.?)).*;
    const tracy_frameProcess = tracy.ZoneN(@src(), "Frame Processing");
    defer tracy_frameProcess.End();

    if (!processor.processNextFrame()) {
        running = false;
        return 0;
    }
    return interval;
}
