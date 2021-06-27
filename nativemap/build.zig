const std = @import("std");

const Root = "C:\\Users\\tsunko\\Desktop\\nativemap\\";
const FFmpegRoot = Root ++ "ffmpeg\\";
const SDL2Root = Root ++ "sdl2\\";
const JVMRoot = Root ++ "jni\\";

pub fn build(b: *std.build.Builder) void {
    const is_sdl = b.option(bool, "sdl", "Build debugging SDL video player") orelse false;
    const is_lut = b.option(bool, "lut", "Build and generate lookup table") orelse false;
    const is_lib = b.option(bool, "lib", "Build library for NativeMap") orelse false;

    const target = b.standardTargetOptions(.{});
    const mode = b.standardReleaseOptions();
    var output: *std.build.LibExeObjStep = undefined;

    if (is_sdl) {
        output = b.addExecutable("sdl-debug-player", "src/sdl-main.zig");
        linkFFmpeg(b, output, false);
        linkSDL(b, output);

        const run_cmd = output.run();
        run_cmd.step.dependOn(b.getInstallStep());
        if (b.args) |args| {
            run_cmd.addArgs(args);
        }
        const run_step = b.step("run", "Run the app");
        run_step.dependOn(&run_cmd.step);
    } else if (is_lut) {
        output = b.addExecutable("lut-gen", "src/lut-main.zig");
        linkFFmpeg(b, output, false);
        linkSDL(b, output);

        const run_cmd = output.run();
        run_cmd.step.dependOn(b.getInstallStep());
        if (b.args) |args| {
            run_cmd.addArgs(args);
        }
        const run_step = b.step("run", "Run the app");
        run_step.dependOn(&run_cmd.step);
    } else if (is_lib) {
        output = b.addSharedLibrary("nativemap", "src/lib.zig", .unversioned);
        linkFFmpeg(b, output, true);
        linkJVM(b, output);
    } else {
        std.debug.print("No build option selected.", .{});
        return;
    }
    output.setTarget(target);
    output.setBuildMode(mode);
    output.linkLibC();
    output.install();
}

fn linkFFmpeg(b: *std.build.Builder, target: *std.build.LibExeObjStep, comptime isLib: bool) void {
    comptime const installer = if (isLib) b.installLibFile else b.installBinFile;
    comptime const folder = if (isLib) "lib" else "bin";

    target.addIncludeDir(FFmpegRoot ++ "include");
    target.addLibPath(FFmpegRoot ++ "lib");
    inline for ([_][]const u8{ "avcodec-58.dll", "swresample-3.dll", "avutil-56.dll", "avformat-58.dll", "swscale-5.dll" }) |dll| {
        const lib = std.mem.split(dll, "-").next().?;
        std.debug.print("Linking and installing {s}\n", .{lib});
        target.linkSystemLibrary(lib);
        installer(FFmpegRoot ++ "bin\\" ++ dll, dll);
    }
}

fn linkSDL(b: *std.build.Builder, target: *std.build.LibExeObjStep) void {
    std.debug.print("Linking and installing {s}\n", .{"SDL2"});
    target.addIncludeDir(SDL2Root ++ "include");
    target.addLibPath(SDL2Root ++ "lib\\x64");
    target.linkSystemLibrary("SDL2");
    b.installBinFile(SDL2Root ++ "lib\\x64\\SDL2.dll", "SDL2.dll");
}

fn linkJVM(b: *std.build.Builder, target: *std.build.LibExeObjStep) void {
    std.debug.print("Linking and installing {s}\n", .{"JNI"});
    target.addIncludeDir(JVMRoot ++ "include");
    target.addIncludeDir(JVMRoot ++ "include\\win32");
}
