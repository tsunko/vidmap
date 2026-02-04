package academy.hekiyou.vidmap;

import io.netty.buffer.ByteBuf;
import io.netty.buffer.Unpooled;
import net.minecraft.network.VarInt;
import net.minecraft.network.codec.StreamCodec;
import net.minecraft.network.protocol.Packet;
import net.minecraft.network.protocol.PacketFlow;
import net.minecraft.network.protocol.PacketType;
import net.minecraft.network.protocol.game.ClientGamePacketListener;
import net.minecraft.resources.Identifier;
import org.jspecify.annotations.NonNull;

import java.lang.foreign.MemorySegment;

public class ClientboundMapBufferedDataPacket implements Packet<ClientGamePacketListener>  {

    public static final PacketType<ClientboundMapBufferedDataPacket> FAKE_TYPE =
            new PacketType<>(PacketFlow.CLIENTBOUND, Identifier.withDefaultNamespace("map_item_data"));

    public static final StreamCodec<ByteBuf, ClientboundMapBufferedDataPacket> STREAM_CODEC =
            Packet.codec(ClientboundMapBufferedDataPacket::write, ClientboundMapBufferedDataPacket::new);

    private final int id;
    private final ByteBuf data;

    public ClientboundMapBufferedDataPacket(int id, MemorySegment segment) {
        this.id = id;

        // TODO: don't make a copy of this - find a way to somehow invalidate this packet when we call adjustOutput
        this.data = Unpooled.copiedBuffer(segment.asByteBuffer());
    }

    private ClientboundMapBufferedDataPacket(ByteBuf byteBuf) {
        throw new UnsupportedOperationException("custom packet received somehow?");
    }

    private void write(@NonNull ByteBuf buffer) {
        VarInt.write(buffer, this.id);                 // id
        buffer.writeByte(0);                     // scale
        buffer.writeBoolean(false);              // locked
        buffer.writeBoolean(false);              // icons present
        buffer.writeByte(128);                   // width
        buffer.writeByte(128);                   // height
        buffer.writeByte(0);                     // start x
        buffer.writeByte(0);                     // start y

        VarInt.write(buffer, 128 * 128);         // map data length
        buffer.writeBytes(this.data, 0, 128 * 128); // map data; hopefully this doesn't do a copy to java's heap?
    }

    @Override
    public boolean isReady() {
        return Packet.super.isReady();
    }

    @Override
    public @NonNull PacketType<? extends Packet<ClientGamePacketListener>> type() {
        return FAKE_TYPE;
    }

    @Override
    public void handle(ClientGamePacketListener listener) {
        throw new UnsupportedOperationException("custom packet received somehow?");
    }

}
