const std = @import("std");
const fbf = @import("frame-by-frame.zig");
const ogg = @import("ogg-extract.zig");
const mc = @import("mc.zig");
const avcommon = @import("av-common.zig");

usingnamespace @cImport({
    @cInclude("jni.h");
    @cInclude("win32/jni_md.h");
});

const MCFrameByFrame = fbf.FrameByFrame(*mc.NativeMapContext);
const GPA = std.heap.GeneralPurposeAllocator(.{});

var gpa: GPA = undefined;

export fn Java_academy_hekiyou_vidmap_NativeMap_createFBF(env: *JNIEnv, class: jclass, jbuffer: jobject, mapW: jint, mapH: jint) callconv(.C) jlong {
    // create context and get the pointer to our direct bytebuffer's backing native array
    const context = gpa.allocator.create(mc.NativeMapContext) catch return -1;
    context.* = .{
        // technically speaking, this is wrong - we shouldn't be using [*]u8, it should be [*]jbyte
        // it doesn't matter in this particular scenario, since minecraft color codes go into the negatives
        .buffer = @ptrCast([*]u8, env.*.*.GetDirectBufferAddress.?(env, jbuffer)),
        .mapWidth = @bitCast(u32, mapW),
        .mapHeight = @bitCast(u32, mapH),
    };
    errdefer gpa.allocator.destroy(context);

    // allocate our struct on heap so it doesn't get lost on stack
    const allocated = gpa.allocator.create(MCFrameByFrame) catch return 0;
    allocated.* = .{
        // use the one pointer we have to pass around the context we're operating in
        // ideally, we would create a generic type out of fbf, but ptrToInt and intToPtr are too convient
        .userData = context,
        // assign the general callback to our allocated fbf
        .callback = mc.toMinecraftColors,
    };

    // and then finally return the structure
    return @intCast(c_longlong, @ptrToInt(allocated));
}

export fn Java_academy_hekiyou_vidmap_NativeMap_setupFBF(env: *JNIEnv, class: jclass, ptr: jlong, jsrc: jstring) callconv(.C) jdouble {
    const allocated = toFBF(ptr);
    const context = allocated.userData;

    // get/copy jsrc and then free once we leave
    const str = env.*.*.GetStringUTFChars.?(env, jsrc, null);
    defer env.*.*.ReleaseStringUTFChars.?(env, jsrc, str);

    // return back the ms delay per frame or -1 if there was an error
    return allocated.setup(str, @truncate(u16, context.mapWidth * 128), @truncate(u16, context.mapHeight * 128)) catch -1.0;
}

export fn Java_academy_hekiyou_vidmap_NativeMap_stepFBF(env: *JNIEnv, class: jclass, ptr: jlong) callconv(.C) bool {
    return toFBF(ptr).stepNextFrame();
}

export fn Java_academy_hekiyou_vidmap_NativeMap_freeFBF(env: *JNIEnv, class: jclass, ptr: jlong) callconv(.C) void {
    const allocated = toFBF(ptr);
    allocated.free();
    gpa.allocator.destroy(allocated.userData);
    gpa.allocator.destroy(allocated);
}

export fn Java_academy_hekiyou_vidmap_NativeMap_initialize(env: *JNIEnv, class: jclass) callconv(.C) void {
    gpa = GPA{};
    avcommon.initAVCodec();
}

export fn Java_academy_hekiyou_vidmap_NativeMap_deinitialize(env: *JNIEnv, class: jclass) callconv(.C) void {
    const leaked = gpa.deinit();
    if (leaked) @panic("leaked something!");
}

export fn Java_academy_hekiyou_vidmap_NativeMap_extractAudio(env: *JNIEnv, class: jclass, jsrc: jstring, jdst: jstring) callconv(.C) bool {
    // get a copy of our java string so we can pass it back to findAndConvertAudio
    const src = env.*.*.GetStringUTFChars.?(env, jsrc, null);
    const dst = env.*.*.GetStringUTFChars.?(env, jdst, null);
    // release when function ends
    defer env.*.*.ReleaseStringUTFChars.?(env, jsrc, src);
    defer env.*.*.ReleaseStringUTFChars.?(env, jdst, dst);

    // it's not actually very easy to find, but GetStringUTFChars does return null terminated strings
    // (see: https://stackoverflow.com/questions/16694239/java-native-code-string-ending)
    var success = true;
    ogg.findAndConvertAudio(src, dst) catch |err| {
        std.log.warn("Encountered error while converting: {s}", .{@errorName(err)});
        success = false;
    };
    return success;
}

inline fn toFBF(ptr: jlong) *MCFrameByFrame {
    return @intToPtr(*MCFrameByFrame, @intCast(usize, ptr));
}
