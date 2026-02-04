const std = @import("std");
const clap = @import("clap");
const nativemap = @import("nativemap");
const c = @cImport({
    @cDefine("__builtin_va_arg_pack", "((void (*)())(0))");
    @cInclude("SDL3/SDL.h");
});

const params = clap.parseParamsComptime(
    \\-h, --help                   Display this help and exit.
    \\-m, --multiplier   <f32>     A multiplier for the internal texture resolution. Does not effect the window size.
    \\-i, --ignore-pts   <bool>    If "true", ignores the pts value for each frame and goes as fast as possible.
    \\-f, --no-frameskip <bool>    If "true", do not skip frames when we start falling behind massively (<= -33.33ms)
    \\<input>
);

const parsers = merge(clap.parsers.default, .{
    .bool = clap.parsers.enumeration(enum { true, false }),
    .input = clap.parsers.default.string,
});

fn multiply(n: usize, multiplier: f64) usize {
    return @intFromFloat(@floor(@as(f64, @floatFromInt(n)) * multiplier));
}

pub fn main(init: std.process.Init) !void {
    const resolved = try clap.parse(clap.Help, &params, parsers, init.minimal.args, .{
        .allocator = init.gpa,
    });
    defer resolved.deinit();
    if (resolved.args.help != 0) {
        var stdoutWriter = std.Io.File.writer(.stdout(), init.io, &.{});
        const interface = &stdoutWriter.interface;
        try clap.help(interface, clap.Help, &params, .{});
        return;
    }

    const videoFilePath = resolved.positionals[0] orelse {
        std.log.err("Missing video file path", .{});
        return;
    };
    const multiplier = resolved.args.multiplier orelse 1;
    const ignorePts = if (resolved.args.@"ignore-pts") |b| b == .true else false;
    const noFrameskip = if (resolved.args.@"no-frameskip") |b| b == .true else false;
        
    var windowWidth: usize = 1920;
    var windowHeight: usize = 1080;

    _ = c.SDL_Init(c.SDL_INIT_VIDEO);

    const window = c.SDL_CreateWindow("SDL Viewer",
        @intCast(windowWidth), @intCast(windowHeight), c.SDL_WINDOW_RESIZABLE) orelse return error.FailedWindowCreate;
    const renderer = c.SDL_CreateRenderer(window, null);
    var texture = c.SDL_CreateTexture(renderer, c.SDL_PIXELFORMAT_INDEX8, c.SDL_TEXTUREACCESS_STREAMING,
        @intCast(@max(1, multiply(windowWidth, multiplier))), @intCast(@max(1, multiply(windowHeight, multiplier))));

    const paletteSource = nativemap.Color.calculateAllShades();
    const palette = c.SDL_CreatePalette(paletteSource.len);
    var paletteColors: [paletteSource.len]c.SDL_Color = undefined;
    for (paletteSource, &paletteColors) |mc, *sdl| {
        sdl.r = mc.r;
        sdl.g = mc.g;
        sdl.b = mc.b;
        sdl.a = 0;
    }
    _ = c.SDL_SetPaletteColors(palette, &paletteColors[0], 0, paletteColors.len);
    _ = c.SDL_SetRenderDrawColor(renderer, 0, 0, 0, 255);
    _ = c.SDL_SetTexturePalette(texture, palette);


    var context: nativemap.Context = .{// we can get away with setting this to an empty buffer because in our main loop,
        // this is set to the texture buffer we get from SDL_LockTexture; it's hacky, but the alternative is to
        // allocate the same array (again), have to manage its lifetime, and do a memcpy in every loop invocation
        .buffer = &.{},
        .dimensions = .{ .pixel = .{ .width = windowWidth, .height = windowHeight }},
        .av = null,
    };
    // defer init.gpa.free(context.buffer);
    try nativemap.Lut.loadTable("lut.dat", init.io, init.gpa);
    const timebase = try context.open(videoFilePath);
    std.log.info("Opened {s}, timebase is {d}", .{ videoFilePath, timebase });


    const startTime = try std.Io.Clock.now(.real, init.io);
    var running = true;
    var frameskip = false;
    while (running) {
        _ = c.SDL_RenderClear(renderer);

        var pixels: [*]u8 = undefined;
        var pitch: c_int = 0;

        _ = c.SDL_LockTexture(texture, null, @ptrCast(&pixels), &pitch);
        defer c.SDL_UnlockTexture(texture);

        context.buffer = pixels[0..multiply(@as(usize, @intCast(pitch)) * windowHeight, multiplier)];

        var pts: i64 = undefined;
        const ret = try context.readFrame(&pts, frameskip);
        if (ret == 0) {
            std.log.info("End of video", .{});
            break;
        }

        const timeNow = try std.Io.Clock.now(.real, init.io);
        const scaledPts = (@as(f64, @floatFromInt(pts))) * timebase;
        const delay = (startTime.nanoseconds + @as(i96, @intFromFloat(scaledPts * std.time.ns_per_s))) - timeNow.nanoseconds;
        const delayInMs = @as(f32, @floatFromInt(delay))/1000000.0;

        // arbitrarily consider anything above 1ms to be delayable; SDL_Delay might not be accurate and end up using
        // a millisecond in itself just trying to start the delay
        if (delayInMs > 2) {
            if (delayInMs > 3) {
                std.log.info("Ahead by {d}ms", .{ delayInMs });
            }

            frameskip = false;
            c.SDL_Delay(@intFromFloat(@round(delayInMs)));
        } else {
            if (delayInMs < -3) {
                std.log.warn("Fell behind by {d}ms", .{ delayInMs });
            }

            if (delayInMs < -33.33/2.0 and !noFrameskip){
                // fell so bar behind that we would be lagging behind half a frame in a 30fps video - start skipping
                frameskip = true;
            }
            // maybe we can catch up, just let it fly
        }

        _ = c.SDL_RenderTexture(renderer, texture, null, null);

        {
            var debugBuffer: [512]u8 = @splat(0);
            const str = try std.fmt.bufPrintZ(&debugBuffer, "current delay: {d}", .{ delayInMs });
            _ = c.SDL_RenderDebugText(renderer, 25, 25, str.ptr);
        }

        _ = c.SDL_RenderPresent(renderer);

        if (ignorePts) {
            continue;
        }

        var event: c.SDL_Event = undefined;
        while (c.SDL_PollEvent(&event)) {
            switch(event.type) {
                c.SDL_EVENT_QUIT => {
                    running = false;
                    break;
                },
                c.SDL_EVENT_WINDOW_PIXEL_SIZE_CHANGED => {
                    var w: i32 = 0;
                    var h: i32 = 0;
                    _ = c.SDL_GetCurrentRenderOutputSize(renderer, &w, &h);

                    const newWidth: usize = @intCast(w);
                    const newHeight: usize = @intCast(h);

                    const textureWidth: usize = @intCast(@max(1, multiply(newWidth, multiplier)));
                    const textureHeight: usize = @intCast(@max(1, multiply(newHeight, multiplier)));

                    try context.adjustOutput(.{ .pixel = .{ .width = textureWidth, .height = textureHeight } });
                    _ = c.SDL_DestroyTexture(texture);
                    texture = c.SDL_CreateTexture(renderer, c.SDL_PIXELFORMAT_INDEX8, c.SDL_TEXTUREACCESS_STREAMING,
                        @intCast(textureWidth), @intCast(textureHeight));
                    _ = c.SDL_SetTexturePalette(texture, palette);

                    std.log.info("Resized internal texture to {d}x{d} (multiplier = {d}, window size = {d}x{d})",
                        .{ textureWidth, textureHeight, multiplier, newWidth, newHeight });

                    windowWidth = newWidth;
                    windowHeight = newHeight;
                },
                else => {},
            }
        }
    }

    _ = c.SDL_DestroyRenderer(renderer);
    _ = c.SDL_DestroyWindow(window);
}


fn merge(a: anytype, b: anytype) mergedStructType(@TypeOf(a), @TypeOf(b)) {
    var result: mergedStructType(@TypeOf(a), @TypeOf(b)) = undefined;
    inline for (@typeInfo(@TypeOf(a)).@"struct".fields) |f| {
        @field(result, f.name) = @field(a, f.name);
    }
    inline for (@typeInfo(@TypeOf(b)).@"struct".fields) |f| {
        @field(result, f.name) = @field(b, f.name);
    }
    return result;
}

const StructField = std.builtin.Type.StructField;
fn mergedStructType(a: type, b: type) type {
    const fields: []const StructField = @typeInfo(a).@"struct".fields ++ @typeInfo(b).@"struct".fields;
    var names: [fields.len][:0]const u8 = undefined;
    var types: [fields.len]type = undefined;
    var attrs: [fields.len]StructField.Attributes = undefined;

    for (0..fields.len) |i| {
        names[i] = fields[i].name;
        types[i] = fields[i].type;
        attrs[i] = .{
            .@"comptime" = false,
            .@"align" = fields[i].alignment,
            .default_value_ptr = null,
        };
    }

    return @Struct(.auto, null, &names, &types, &attrs);
}