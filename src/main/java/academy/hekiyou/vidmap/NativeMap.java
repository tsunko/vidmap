package academy.hekiyou.vidmap;

import java.nio.ByteBuffer;

public final class NativeMap {

    public static native long createFBF(ByteBuffer recipient, int mapW, int mapH);

    public static native double setupFBF(long fbfPointer, String source);

    public static native boolean stepFBF(long fbfPointer);

    public static native void freeFBF(long fbfPointer);

    public static native void initialize();

    public static native void deinitialize();

    public static native boolean extractAudio(String source, String destination);

}
