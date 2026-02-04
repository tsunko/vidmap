const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const nativemap = b.addModule("nativemap", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    nativemap.addLibraryPath(b.path("ffmpeg/bin/lib/"));
    nativemap.addIncludePath(b.path("ffmpeg/bin/include/"));
    nativemap.linkSystemLibrary("avcodec", .{});
    nativemap.linkSystemLibrary("avformat", .{});
    nativemap.linkSystemLibrary("avutil", .{});
    nativemap.linkSystemLibrary("swscale", .{});
    nativemap.linkSystemLibrary("swresample", .{});

    const lib = b.addLibrary(.{
        .name = "nativemap",
        .root_module = nativemap,
        .linkage = .dynamic,
    });

    const clap = b.dependency("clap", .{});
    const sdl = b.dependency("sdl", .{
        .target = target,
        .optimize = optimize,
    });
    const sdl_viewer = b.addExecutable(.{
        .name = "sdl_viewer",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/sdl_viewer/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "nativemap", .module = nativemap },
                .{ .name = "clap", .module = clap.module("clap") }
            },
            .link_libc = true,
        }),
    });
    sdl_viewer.root_module.linkLibrary(lib);
    sdl_viewer.root_module.linkLibrary(sdl.artifact("SDL3"));

    b.installArtifact(lib);
    b.installArtifact(sdl_viewer);


    // const options = .{
    //     .enable_ztracy = b.option(
    //         bool,
    //         "enable_ztracy",
    //         "Enable Tracy profile markers",
    //     ) orelse false,
    // };
    //
    // const nativemap_mod = b.createModule(.{
    //     .root_source_file = b.path("src/lib.zig"),
    //     .target = target,
    //     .optimize = optimize,
    // });
    // const ztracy = b.dependency("ztracy", .{
    //     .enable_ztracy = options.enable_ztracy,
    //     .enable_fibers = false,
    //     .on_demand = false,
    // });
    // nativemap_mod.addImport("ztracy", ztracy.module("root"));
    // nativemap_mod.linkLibrary(ztracy.artifact("tracy"));
    // nativemap_mod.addLibraryPath(b.path("ffmpeg/bin/lib/"));
    // nativemap_mod.addIncludePath(b.path("ffmpeg/bin/include/"));
    // nativemap_mod.linkSystemLibrary("avcodec", .{});
    // nativemap_mod.linkSystemLibrary("avformat", .{});
    // nativemap_mod.linkSystemLibrary("avutil", .{});
    // nativemap_mod.linkSystemLibrary("swscale", .{});
    //
    // const convert_image_mod = b.createModule(.{
    //     .root_source_file = b.path("src/convert_image_cli.zig"),
    //     .target = target,
    //     .optimize = optimize,
    // });
    // convert_image_mod.addImport("nativemap", nativemap_mod);
    //
    // const generate_lut_mod = b.createModule(.{
    //     .root_source_file = b.path("src/generate_lut.zig"),
    //     .target = target,
    //     .optimize = optimize,
    // });
    // generate_lut_mod.addImport("nativemap", nativemap_mod);
    //
    // const sdl_viewer_mod = b.createModule(.{
    //     .root_source_file = b.path("src/sdl_viewer.zig"),
    //     .target = target,
    //     .optimize = optimize,
    // });
    // const sdl = b.dependency("sdl", .{
    //     .target = target,
    //     .optimize = optimize,
    // });
    // const sdl_artifact = sdl.artifact("SDL3");
    // sdl_viewer_mod.addSystemIncludePath(.{ .cwd_relative = "/usr/include/SDL3/" });
    // sdl_viewer_mod.addImport("ztracy", ztracy.module("root"));
    // sdl_viewer_mod.addImport("nativemap", nativemap_mod);
    // sdl_viewer_mod.linkLibrary(sdl_artifact);
    // sdl_viewer_mod.linkLibrary(ztracy.artifact("tracy"));
    //
    // const libnativemap = b.addLibrary(.{
    //     .name = "nativemap",
    //     .linkage = .dynamic,
    //     .root_module = nativemap_mod,
    // });
    // b.installArtifact(libnativemap);
    //
    // const convert_image = b.addExecutable(.{
    //     .name = "convert_image",
    //     .root_module = convert_image_mod,
    // });
    // b.installArtifact(convert_image);
    //
    // const generate_lut = b.addExecutable(.{
    //     .name = "generate_lut",
    //     .root_module = generate_lut_mod,
    // });
    // b.installArtifact(generate_lut);
    //
    // const sdl_viewer = b.addExecutable(.{
    //     .name = "sdl_viewer",
    //     .root_module = sdl_viewer_mod,
    // });
    // b.installArtifact(sdl_viewer);
}
