const std = @import("std");
const fs = std.fs;

const Allocator = std.mem.Allocator;
const Builder = std.build.Builder;

var root: []const u8 = undefined;
var allocator: *Allocator = undefined;

// set to true if we want tracy to record frame/function times, false if we just want stubbed
var enable_tracy = true;

pub fn build(b: *Builder) void {
    const target = b.standardTargetOptions(.{});
    const mode = b.standardReleaseOptions();

    root = b.build_root;
    allocator = b.allocator;

    {
        const debugPlayer = b.addExecutable("sdl-debug-player", "src/sdl-main.zig");
        debugPlayer.setTarget(target);
        debugPlayer.setBuildMode(mode);
        debugPlayer.linkLibC();
        debugPlayer.want_lto = false;
        buildWithSDL2(debugPlayer);
        buildWithFFmpeg(debugPlayer);
        buildWithTracy(debugPlayer);
        debugPlayer.install();

        const runDebugPlayer = debugPlayer.run();
        runDebugPlayer.cwd = b.exe_dir;

        const runDebugStep = b.step("debug", "Run the debug player");
        runDebugStep.dependOn(&runDebugPlayer.step);
    }
    {
        const lutGen = b.addExecutable("lut-gen", "src/lut-main.zig");
        lutGen.setTarget(target);
        lutGen.setBuildMode(mode);
        lutGen.install();
    }
    {
        const jniLib = b.addSharedLibrary("nativemap", "src/lib.zig", b.version(0, 0, 1));
        jniLib.setTarget(target);
        jniLib.setBuildMode(mode);
        jniLib.linkLibC();
        buildWithJNI(jniLib);
        buildWithFFmpeg(jniLib);
        buildWithTracy(jniLib);
        jniLib.install();
    }
}

fn buildWithSDL2(target: *std.build.LibExeObjStep) void {
    target.addIncludeDir(joinWithRoot("\\sdl2\\include"));
    target.addLibPath(joinWithRoot("\\sdl2\\lib\\x64"));
    target.linkSystemLibrary("sdl2");
}

fn buildWithFFmpeg(target: *std.build.LibExeObjStep) void {
    target.addIncludeDir(joinWithRoot("\\ffmpeg\\include"));
    target.addLibPath(joinWithRoot("\\ffmpeg\\lib"));
    target.linkSystemLibrary("avcodec");
    target.linkSystemLibrary("swresample");
    target.linkSystemLibrary("avutil");
    target.linkSystemLibrary("avformat");
    target.linkSystemLibrary("swscale");
}

fn buildWithJNI(target: *std.build.LibExeObjStep) void {
    target.addIncludeDir(joinWithRoot("\\jni\\include"));
    target.addIncludeDir(joinWithRoot("\\jni\\include\\win32"));
}

fn buildWithTracy(target: *std.build.LibExeObjStep) void {
    const tracyPath = joinWithRoot("\\tracy-0.7.8");
    target.addBuildOption(bool, "tracy_enabled", enable_tracy);
    target.addIncludeDir(tracyPath);
    const tracyClient = std.fs.path.join(allocator, &.{ tracyPath, "TracyClient.cpp" }) catch unreachable;
    target.addCSourceFile(tracyClient, &.{
        "-fno-sanitize=undefined",
        "-DTRACY_ENABLE",
        "-D_WIN32_WINNT=0x601",
    });

    // if building from source, make sure you change this to match your specific windows SDK install
    target.addLibPath("C:\\Program Files (x86)\\Microsoft Visual Studio\\2019\\Community\\VC\\Tools\\MSVC\\14.29.30037\\lib\\x64");
    target.linkSystemLibrary("DbgHelp");
    target.linkSystemLibrary("Advapi32");
    target.linkSystemLibrary("User32");
    target.linkSystemLibrary("Ws2_32");

    target.linkLibC();
    target.linkSystemLibrary("c++");
}

fn joinWithRoot(path: []const u8) []const u8 {
    return fs.path.join(allocator, &.{ root, path }) catch unreachable;
}
