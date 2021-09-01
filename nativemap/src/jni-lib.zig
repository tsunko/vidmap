const std = @import("std");
const FrameProcessorBase = @import("frame-processor.zig").FrameProcessor;
const mc = @import("mc.zig");
const audio = @import("audio-extractor.zig");

usingnamespace @cImport({
    @cInclude("jni.h");
    @cInclude("win32/jni_md.h");
});

const MinecraftFrameProcessor = FrameProcessorBase(*mc.NativeMapContext);
var allocator: *std.mem.Allocator = std.heap.c_allocator;
var pointerID: jfieldID = undefined;

// Internal native functions

export fn Java_academy_hekiyou_vidmap_NativeMap__1_1createNativeContext(
    env: *JNIEnv,
    instance: jobject,
    buffer: jobject,
    width: jint,
    height: jint,
) callconv(.C) jlong {
    _ = instance;

    var context = allocator.create(mc.NativeMapContext) catch return 0;
    context.buffer = @ptrCast([*]u8, env.*.*.GetDirectBufferAddress.?(env, buffer));
    context.mapWidth = @truncate(u16, @intCast(c_ulong, width));
    context.mapHeight = @truncate(u16, @intCast(c_ulong, height));

    var processor = allocator.create(MinecraftFrameProcessor) catch {
        allocator.destroy(context);
        return 0;
    };
    processor.userData = context;
    processor.callback = mc.toMinecraftColors;

    return @intCast(jlong, @ptrToInt(processor));
}

export fn Java_academy_hekiyou_vidmap_NativeMap__1_1open(
    env: *JNIEnv,
    instance: jobject,
    jsource: jstring,
) callconv(.C) jdouble {
    const source = env.*.*.GetStringUTFChars.?(env, jsource, null);
    defer env.*.*.ReleaseStringUTFChars.?(env, jsource, source);
    var processor = deriveProcessor(env, instance) catch return -1.0;
    var context = processor.userData.?;

    return processor.open(source, context.mapWidth * 128, context.mapHeight * 128) catch -1.0;
}

export fn Java_academy_hekiyou_vidmap_NativeMap__1_1processNextFrame(
    env: *JNIEnv,
    instance: jobject,
) callconv(.C) jboolean {
    var processor = deriveProcessor(env, instance) catch return 0;
    return if (processor.processNextFrame()) 1 else 0;
}

export fn Java_academy_hekiyou_vidmap_NativeMap__1_1free(
    env: *JNIEnv,
    instance: jobject,
) callconv(.C) void {
    var processor = deriveProcessor(env, instance) catch return;
    processor.close() catch @panic("Failed to close frame processor");
}

// Global functions that require no instance

export fn Java_academy_hekiyou_vidmap_NativeMap_initialize(
    env: *JNIEnv,
    class: jclass,
) callconv(.C) void {
    pointerID = env.*.*.GetFieldID.?(env, class, "__pointer", "J");
}

export fn Java_academy_hekiyou_vidmap_NativeMap_deinitialize(
    env: *JNIEnv,
    class: jclass,
) callconv(.C) void {
    _ = env;
    _ = class;
    // is there anything to deinitialize
}

export fn Java_academy_hekiyou_vidmap_NativeMap_extractAudio(
    env: *JNIEnv,
    class: jclass,
    jsrc: jstring,
    jdst: jstring,
) callconv(.C) bool {
    _ = env;
    _ = class;
    _ = jsrc;
    _ = jdst;
    const src = env.*.*.GetStringUTFChars.?(env, jsrc, null);
    defer env.*.*.ReleaseStringUTFChars.?(env, jsrc, src);

    const dst = env.*.*.GetStringUTFChars.?(env, jdst, null);
    defer env.*.*.ReleaseStringUTFChars.?(env, jdst, dst);

    audio.extractAudio(src, dst) catch return false;
    return true;
}

inline fn deriveProcessor(env: *JNIEnv, instance: jobject) !*MinecraftFrameProcessor {
    var jpointer: jlong = env.*.*.GetLongField.?(env, instance, pointerID);
    if (jpointer == -1)
        return error.Uninitialized;
    return @intToPtr(*MinecraftFrameProcessor, @intCast(usize, jpointer));
}

inline fn deriveContext(env: *JNIEnv, instance: jobject) !mc.NativeMapContext {
    return deriveProcessor(env, instance).userData;
}
