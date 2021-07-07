const std = @import("std");

const c = @cImport({
    @cInclude("SDL.h");
});

const SDL_Window = c.struct_SDL_Window;
const SDL_Renderer = c.struct_SDL_Renderer;
const SDL_Texture = c.struct_SDL_Texture;
const SDL_Rect = c.struct_SDL_Rect;

pub fn initSDL() void {
    // init SDL for video and timer
    if (c.SDL_Init(c.SDL_INIT_VIDEO | c.SDL_INIT_TIMER) != 0) {
        return;
    }
}

pub fn createViewer() SDLViewer {
    return .{};
}

pub const SDLViewerError = error{ FailedWindowCreation, FailedRendererCreation, FailedTextureCreation };

pub const SDLViewer = struct {
    const Self = @This();

    window: ?*SDL_Window = undefined,
    renderer: ?*SDL_Renderer = undefined,
    texture: ?*SDL_Texture = undefined,
    bounds: SDL_Rect = undefined,
    width: u16 = 0,
    height: u16 = 0,
    needsResize: bool = false,

    pub fn setup(self: *Self, width: u16, height: u16) !void {
        self.width = width;
        self.height = height;

        // zig fmt: off
        self.window = c.SDL_CreateWindow(
            // title
            "Debug Player",
            // where on the screen to display
            c.SDL_WINDOWPOS_UNDEFINED, c.SDL_WINDOWPOS_UNDEFINED,
            // width and height of the window
            width, height,
            // flags
            c.SDL_WINDOW_OPENGL | c.SDL_WINDOW_ALLOW_HIGHDPI | c.SDL_WINDOW_RESIZABLE | c.SDL_WINDOW_MAXIMIZED 
        );
        // zig fmt: on

        if (self.window == null) {
            return SDLViewerError.FailedWindowCreation;
        }

        try createRendererAndTexture(self);

        // zig fmt: off
        self.bounds = .{
            .x = 0,
            .y = 0,
            .w = width,
            .h = height,
        };
        // zig fmt: on
    }

    pub fn drawFrameCallback(self: *Self, data: [*]const u8) void {
        if (self.needsResize) {
            c.SDL_DestroyRenderer(self.renderer);
            createRendererAndTexture(self) catch @panic("Failed to recreate renderer/texture");
            self.needsResize = false;
        }

        // clear our window
        _ = c.SDL_RenderClear(self.renderer);

        // zig fmt: off
        // update our texture
        _ = c.SDL_UpdateTexture(
            self.texture, &self.bounds, 
            data, self.width * 2
        );
        // zig fmt: on

        // zig fmt: off
        // render the texture on screen
        _ = c.SDL_RenderCopy(
            self.renderer,
            self.texture,
            null,
            null
        );
        // zig fmt: on

        // and then present it
        _ = c.SDL_RenderPresent(self.renderer);
    }

    pub fn checkEvents(self: *Self) bool {
        var event: c.SDL_Event = undefined;
        _ = c.SDL_PollEvent(&event);
        switch (event.type) {
            c.SDL_WINDOWEVENT => {
                if (event.window.event == c.SDL_WINDOWEVENT_SIZE_CHANGED) {
                    std.debug.print("Recreating renderer due to window resize.\n", .{});
                    self.needsResize = true;
                }
            },
            c.SDL_QUIT => {
                std.debug.print("Got quit event - quitting.\n", .{});
                return true;
            },
            else => {},
        }
        return false;
    }

    fn createRendererAndTexture(self: *Self) !void {
        // zig fmt: off
        self.renderer = c.SDL_CreateRenderer(
            self.window, 
            -1, 
            c.SDL_RENDERER_ACCELERATED | c.SDL_RENDERER_PRESENTVSYNC | c.SDL_RENDERER_TARGETTEXTURE
        );

        if (self.renderer == null) {
            return SDLViewerError.FailedRendererCreation;
        }

        self.texture = c.SDL_CreateTexture(
            self.renderer, 
            c.SDL_PIXELFORMAT_ARGB4444, 
            c.SDL_TEXTUREACCESS_STREAMING, 
            self.width, self.height
        );         
        
        if (self.texture == null) {
            return SDLViewerError.FailedTextureCreation;
        }
        // zig fmt: on
    }

    pub fn freeSDLViewer(self: *Self) void {
        c.SDL_DestroyRenderer(self.renderer);
        c.SDL_Quit();
    }
};
