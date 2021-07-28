package academy.hekiyou.vidmap;

import java.io.File;
import java.nio.ByteBuffer;
import java.util.ArrayList;
import java.util.List;

public final class NativeMap {

    private static final int MAP_BYTE_SIZE = 128 * 128;

    private long __pointer;
    private final PacketPlayOutBufferBackedMap[] packets;

    public NativeMap(int width, int height){
        int count = width * height;

        ByteBuffer mapBuffer = ByteBuffer.allocateDirect(count * MAP_BYTE_SIZE);
        __pointer = __createNativeContext(mapBuffer, width, height);
        packets = getSlicedPackets(mapBuffer, count);
    }

    // Front facing functions that have pointer checks (if we interact with back-end)

    public PacketPlayOutBufferBackedMap[] getPackets() {
        return packets;
    }

    public double open(String source){
        verifyPointer();
        return __open(source);
    }

    public boolean processNextFrame(){
        verifyPointer();
        return __processNextFrame();
    }

    public void free(){
        verifyPointer();
        __free();
        __pointer = -1;
    }

    // Internal native functions to callback to the Zig back-end

    private native long __createNativeContext(ByteBuffer buffer, int width, int height);

    private native double __open(String source);

    private native boolean __processNextFrame();

    private native void __free();

    // Utility functions

    private PacketPlayOutBufferBackedMap[] getSlicedPackets(ByteBuffer source, int mapCount){
        List<PacketPlayOutBufferBackedMap> packets = new ArrayList<>();
        for(int i=0; i < mapCount; i++) {
            ByteBuffer slice = source.slice(i * MAP_BYTE_SIZE, MAP_BYTE_SIZE);
            packets.add(new PacketPlayOutBufferBackedMap(i, slice));
        }
        return packets.toArray(new PacketPlayOutBufferBackedMap[0]);
    }

    private void verifyPointer(){
        if(__pointer == -1)
            throw new IllegalStateException("bad pointer!");
    }

    // Global functions that are used outside of this specific NativeMap.

    public static native void initialize();

    public static native boolean extractAudio(String source, String destination);

    public static native void deinitialize();

}
