package academy.hekiyou.vidmap;


import net.minecraft.network.PacketDataSerializer;
import net.minecraft.network.protocol.game.PacketPlayOutMap;

import java.nio.ByteBuffer;

public class ReusableMapPacket extends PacketPlayOutMap {

    private final int id;
    private final ByteBuffer data;

    public ReusableMapPacket(int id, ByteBuffer data){
        super(0, (byte) 0, false, null, null);
        if(!data.isDirect())
            throw new IllegalArgumentException("expected direct buffer for native lib");
        this.id = id;
        this.data = data;
    }

    // write function
    @Override
    public void a(PacketDataSerializer serializer) {
        // start by writing id
        serializer.d(id);

        // write scale
        serializer.writeByte(0);

        // write tracking state
        serializer.writeBoolean(false);
        // write map locked state
        serializer.writeBoolean(false);

        // columns = 128, "frame" refresh
        serializer.writeByte(128);
        // rows = 128, "frame" refresh
        serializer.writeByte(128);

        // write that our data starts from 0,0 (top-left)
        serializer.writeByte(0);
        serializer.writeByte(0);

        // write length of data
        serializer.d(128 * 128);
        // write data
        serializer.writeBytes(data);
        // then rewind it back for the next frame
        data.rewind();
    }

}
