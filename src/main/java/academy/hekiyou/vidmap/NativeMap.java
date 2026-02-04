package academy.hekiyou.vidmap;

import java.io.IOException;
import java.lang.foreign.*;
import java.lang.invoke.MethodHandle;
import java.nio.file.Path;

/// A map's pixel data that is backed by a foreign memory segment, otherwise "native" and not managed by Java.=
public final class NativeMap implements AutoCloseable {

    private MemorySegment backing;
    private short mapWidth, mapHeight;
    private MemorySegment context;
    private double timebase;
    private double currentPts;
    private long startTime = -1;

    public static void initNativeMap(Path lutPath) {
        try (Arena arena = Arena.ofConfined()) {
            MemorySegment path = arena.allocateFrom(lutPath.toString());
            try {
                GLOBAL_INIT.invoke(path);
            } catch (Throwable t) {
                throw new RuntimeException(t);
            }
        }
    }

    public NativeMap(short width, short height) {
        this.mapWidth = width;
        this.mapHeight = height;
        try {
            this.context = (MemorySegment) ALLOC_CONTEXT_HANDLE.invokeExact(this.mapWidth, this.mapHeight);
        } catch (Throwable t) {
            throw new RuntimeException(t);
        }
    }

    public void open(String src) throws IOException {
        try (Arena arena = Arena.ofConfined()) {
            MemorySegment srcPtr = arena.allocateFrom(src);
            MemorySegment timebasePtr = arena.allocateFrom(ValueLayout.JAVA_DOUBLE, 0);
            int status = (int) OPEN_INPUT_HANDLE.invokeExact(this.context, srcPtr, timebasePtr);
            if (status < 0) {
                throw new RuntimeException("Error while getting next frame: " + status);
            }
            this.timebase = timebasePtr.get(ValueLayout.JAVA_DOUBLE, 0);
        } catch (RuntimeException e) {
            throw e;
        } catch (Throwable t) {
            throw new IOException(t);
        }
    }

    public MemorySegment getBuffer() {
        try {
            return ((MemorySegment)GET_BUFFER_HANDLE.invokeExact(this.context)).reinterpret((long) getMapCount() * 128 * 128);
        } catch (Throwable t) {
            throw new RuntimeException(t);
        }
    }

    public boolean nextFrame() {
        if (startTime == -1) {
            startTime = System.currentTimeMillis();
        }

        try (Arena arena = Arena.ofConfined()) {
            MemorySegment ptsSegment = arena.allocateFrom(ValueLayout.JAVA_LONG, 0);
            int status = (int) READ_FRAME_HANDLE.invoke(this.context, ptsSegment);
            if (status == 0) {
                return false;
            } else if (status < 0) {
                throw new RuntimeException("Error while getting next frame: " + status);
            }
            this.currentPts = ptsSegment.get(ValueLayout.JAVA_LONG, 0);
        } catch (RuntimeException e) {
            throw e;
        } catch (Throwable t) {
            throw new RuntimeException(t);
        }
        return true;
    }

    public void adjustOutput(short mapWidth, short mapHeight) {
        try {
            int status = (int) ADJUST_OUTPUT_HANDLE.invokeExact(this.context, mapWidth, mapHeight);
            if (status < 0) {
                throw new RuntimeException("Error adjusting output: " + status);
            }
            this.mapWidth = mapWidth;
            this.mapHeight = mapHeight;
        } catch (RuntimeException e) {
            throw e;
        } catch (Throwable t) {
            throw new RuntimeException(t);
        }
    }

    @Override
    public void close() {
        this.backing = null;
        try {
            FREE_CONTEXT_HANDLE.invokeExact(this.context);
        } catch (Throwable t) {
            throw new RuntimeException(t);
        }
    }

    public int getMapCount() {
        return this.mapWidth * this.mapHeight;
    }

    public long suggestDelay(long minimum) {
        long actualDelay = (startTime + (long)((this.currentPts * this.timebase) * 1000.0)) - System.currentTimeMillis();
        if (actualDelay < minimum) return 0;
        return actualDelay;
    }

    // NOTE: this leaks the loaded library until the class is unloaded; this is fine since the plugin shouldn't be
    // reloaded multiple times.
    private static final MethodHandle GLOBAL_INIT;
    private static final MethodHandle ALLOC_CONTEXT_HANDLE;
    private static final MethodHandle GET_BUFFER_HANDLE;
    private static final MethodHandle OPEN_INPUT_HANDLE;
    private static final MethodHandle READ_FRAME_HANDLE;
    private static final MethodHandle ADJUST_OUTPUT_HANDLE;
    private static final MethodHandle FREE_CONTEXT_HANDLE;

    static {
        Linker linker = Linker.nativeLinker();
        SymbolLookup lookup = SymbolLookup.libraryLookup(Path.of("libnativemap.so"), Arena.ofAuto());

        // export fn nativemap_global_init(lutPath: ?[*:0]const u8) bool
        GLOBAL_INIT = linker.downcallHandle(lookup.findOrThrow("nativemap_global_init"),
                FunctionDescriptor.of(ValueLayout.JAVA_BYTE, ValueLayout.ADDRESS));

        // export fn nativemap_alloc_context(mapWidth: c_short, mapHeight: c_short) ?*Context
        ALLOC_CONTEXT_HANDLE = linker.downcallHandle(lookup.findOrThrow("nativemap_alloc_context"),
                FunctionDescriptor.of(ValueLayout.ADDRESS, ValueLayout.JAVA_SHORT, ValueLayout.JAVA_SHORT));

        // export fn nativemap_get_buffer(ctx: ?*Context) [*]const u8
        GET_BUFFER_HANDLE = linker.downcallHandle(lookup.findOrThrow("nativemap_get_buffer"),
                FunctionDescriptor.of(ValueLayout.ADDRESS, ValueLayout.ADDRESS));

        // export fn nativemap_open_input(ctx: ?*Context, src: ?[*:0]u8, timescaleOut: ?*f64) c_int
        OPEN_INPUT_HANDLE = linker.downcallHandle(lookup.findOrThrow("nativemap_open_input"),
                FunctionDescriptor.of(ValueLayout.JAVA_INT, ValueLayout.ADDRESS, ValueLayout.ADDRESS, ValueLayout.ADDRESS));

        // export fn nativemap_read_frame(ctx: ?*Context, ptsOut: ?*c_long) c_int
        READ_FRAME_HANDLE = linker.downcallHandle(lookup.findOrThrow("nativemap_read_frame"),
                FunctionDescriptor.of(ValueLayout.JAVA_INT, ValueLayout.ADDRESS, ValueLayout.ADDRESS));

        // export fn nativemap_adjust_output(ctx: ?*Context, newMapWidth: c_short, newMapHeight: c_short) c_int
        ADJUST_OUTPUT_HANDLE = linker.downcallHandle(lookup.findOrThrow("nativemap_adjust_output"),
                FunctionDescriptor.of(ValueLayout.JAVA_INT, ValueLayout.ADDRESS, ValueLayout.JAVA_SHORT, ValueLayout.JAVA_SHORT));

        // export fn nativemap_free_context(ctx: ?*Context) void
        FREE_CONTEXT_HANDLE = linker.downcallHandle(lookup.findOrThrow("nativemap_free_context"),
                FunctionDescriptor.ofVoid(ValueLayout.ADDRESS));
    }

}
