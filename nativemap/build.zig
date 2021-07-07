const std = @import("std");
const Builder = std.build.Builder;

pub fn build(b: *Builder) void {
    const target = b.standardTargetOptions(.{});
    const mode = b.standardReleaseOptions();

    const debugPlayer = b.addExecutable("sdl-debug-player", "src/sdl-main.zig");
    debugPlayer.setTarget(target);
    debugPlayer.setBuildMode(mode);
    debugPlayer.linkLibC();
    buildWithSDL2(debugPlayer);
    buildWithFFmpeg(debugPlayer);
    debugPlayer.install();

    const lutGen = b.addExecutable("lut-gen", "src/lut-main.zig");
    lutGen.setTarget(target);
    lutGen.setBuildMode(mode);
    lutGen.install();

    const jniLib = b.addSharedLibrary("nativemap", "src/lib.zig", b.version(0, 0, 1));
    jniLib.setTarget(target);
    jniLib.setBuildMode(mode);
    jniLib.linkLibC();
    buildWithJNI(jniLib);
    buildWithFFmpeg(jniLib);
    jniLib.install();
}

fn buildWithSDL2(target: *std.build.LibExeObjStep) void {
    target.addIncludeDir("sdl2\\include");
    target.addLibPath("sdl2\\lib\\x64");
    target.linkSystemLibrary("sdl2");
}

fn buildWithFFmpeg(target: *std.build.LibExeObjStep) void {
    target.addIncludeDir("ffmpeg\\include");
    target.addLibPath("ffmpeg\\lib");
    target.linkSystemLibrary("avcodec");
    target.linkSystemLibrary("swresample");
    target.linkSystemLibrary("avutil");
    target.linkSystemLibrary("avformat");
    target.linkSystemLibrary("avfilter");
    target.linkSystemLibrary("avdevice");
    target.linkSystemLibrary("swscale");
}

fn buildWithJNI(target: *std.build.LibExeObjStep) void {
    target.addIncludeDir("jni\\include");
    target.addIncludeDir("jni\\include\\win32");
}
