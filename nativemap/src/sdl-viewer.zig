const std = @import("std");
const tracy = @import("tracy.zig");
usingnamespace @cImport({
    @cInclude("SDL.h");
});

// the only two functions that you can set this without breaking is SDL_BlitSurface and SDL_BlitScaled
// note: if you use SDL_BlitScaled, there is a _massive_ performance penalty, obviously due to scaling
const BlitStrategy = SDL_BlitSurface;

pub fn initSDL() void {
    // init SDL for video and timer
    if (SDL_Init(SDL_INIT_VIDEO | SDL_INIT_TIMER) != 0) {
        return;
    }
}

pub fn createViewer() SDLViewer {
    return .{};
}

pub const SDLViewerError = error{ FailedWindowCreation, FailedRendererCreation, FailedTextureCreation };

pub const SDLViewer = struct {
    const Self = @This();

    window: *SDL_Window = undefined,
    video_surface: *SDL_Surface = undefined,
    width: u16 = undefined,
    height: u16 = undefined,

    pub fn setup(self: *Self, width: u16, height: u16) !void {
        self.window = SDL_CreateWindow(
            "MC SDL-Based Debug Player",
            SDL_WINDOWPOS_CENTERED,
            SDL_WINDOWPOS_CENTERED,
            width,
            height,
            SDL_WINDOW_MAXIMIZED,
        ).?;

        self.width = width;
        self.height = height;

        // create surface for our video data
        // note that we should really be initializing it this way - however, it's easier to merely set pixels to the data pointer
        // rather than doing another huge copy over
        self.video_surface = SDL_CreateRGBSurfaceWithFormat(0, 0, 0, 16, SDL_PIXELFORMAT_RGB444);
        self.video_surface.*.flags |= SDL_PREALLOC;
        self.video_surface.*.w = width;
        self.video_surface.*.h = height;
        self.video_surface.*.pitch = self.width * 2;
        _ = SDL_SetClipRect(self.video_surface, null);
    }

    pub fn drawFrameCallback(self: *Self, data: [*]const u8) void {
        self.video_surface.*.pixels = @intToPtr([*]u8, @ptrToInt(data));

        const tracy_BlitScaled = tracy.ZoneN(@src(), "SDL_BlitScaled");
        _ = BlitStrategy(self.video_surface, null, SDL_GetWindowSurface(self.window), null);
        tracy_BlitScaled.End();

        const tracy_UpdateWindowSurface = tracy.ZoneN(@src(), "SDL_UpdateWindowSurface");
        _ = SDL_UpdateWindowSurface(self.window);
        tracy_UpdateWindowSurface.End();
    }

    pub fn checkEvents(self: *Self) bool {
        _ = self;

        var event: SDL_Event = undefined;
        _ = SDL_PollEvent(&event);
        if (event.type == SDL_QUIT) {
            std.debug.print("Got quit event\n", .{});
            return false;
        }

        return true;
    }

    pub fn exit(self: *Self) void {
        _ = self;
        SDL_Quit();
    }
};
