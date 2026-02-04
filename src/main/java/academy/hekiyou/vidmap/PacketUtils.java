package academy.hekiyou.vidmap;

import io.netty.buffer.ByteBuf;
import it.unimi.dsi.fastutil.objects.Object2IntMap;
import net.minecraft.network.PacketEncoder;
import net.minecraft.network.ProtocolInfo;
import net.minecraft.network.codec.StreamCodec;
import net.minecraft.network.protocol.Packet;
import net.minecraft.network.protocol.game.GamePacketTypes;
import org.bukkit.craftbukkit.entity.CraftPlayer;
import org.bukkit.entity.Player;

import java.lang.reflect.*;
import java.util.ArrayList;
import java.util.Collections;
import java.util.List;

/// Helper class to handle injecting our custom packet codec into Minecraft's own protocol and to sending that packet.
/// Just as a warning, this is probably extremely brittle and will break at the slightest change.
public class PacketUtils {

    @SuppressWarnings({"RawUseOfParameterized", "unchecked"})
    public static void injectPacket(Player player) {
        try {
            // get the two objects responsible for determining how to encode a given packet
            PacketEncoder<?> encoder = (PacketEncoder<?>) ((CraftPlayer)player).getHandle().connection.connection.channel.pipeline().get("encoder");
            ProtocolInfo<?> protocolInfo = access(encoder, ProtocolInfo.class, "protocolInfo");

            // the actual implementing class is specifically an IdDispatchCodec
            StreamCodec<?, ?> codec = protocolInfo.codec();
            Object2IntMap<?> toId = access(codec, Object2IntMap.class, "toId");
            List byId = access(codec, List.class, "byId");

            // get the current id and its associated entry - this might change as time goes on
            // entry type is a record that we can't access directly, so just refer to it as a plain old Object
            int id = toId.getInt(GamePacketTypes.CLIENTBOUND_MAP_ITEM_DATA);
            Object entry = byId.get(id);

            // create proxy codec that will call our encoding routine only when it's our special packet
            // its required to otherwise the server doesn't know how to encode our packet
            ProxyStreamCodec<? extends ByteBuf, ClientboundMapBufferedDataPacket> proxyCodec = new ProxyStreamCodec<>(
                    access(entry, StreamCodec.class, "serializer"),
                    ClientboundMapBufferedDataPacket.STREAM_CODEC,
                    ClientboundMapBufferedDataPacket.class
            );

            // create a proxy lookup entry for our codec, and then replace the existing entry with it
            Object proxyEntry = create(entry.getClass(), StreamCodec.class, Object.class,
                                                         proxyCodec, access(entry, "type"));
            List newById = new ArrayList(byId);
            newById.set(id, proxyEntry);

            // now do magic and set the lookup table with our modified one
            tamper(codec, "byId", Collections.unmodifiableList(newById));
        } catch (Throwable e) {
            throw new RuntimeException(e);
        }
    }

    public static void sendPacket(Player player, Packet<?> packet) {
        ((CraftPlayer)player).getHandle().connection.send(packet);
    }

    public static void sendPackets(Player player, Packet<?>[] packets) {
        for (Packet<?> packet : packets) {
            sendPacket(player, packet);
        }
    }

    private record ProxyStreamCodec<B, V>(StreamCodec<B, Object> original, StreamCodec<B, V> proxy,
                                          Class<V> proxyType) implements StreamCodec<B, Object> {

        @Override
        public Object decode(B inBuffer) {
            return original.decode(inBuffer);
        }

        @Override
        public void encode(B outBuffer, Object inObj) {
            if (proxyType.isInstance(inObj)) {
                proxy.encode(outBuffer, proxyType.cast(inObj));
            } else {
                original.encode(outBuffer, inObj);
            }
        }
    }

    // all the reflection helpers down below are mostly quality of life wrappers and will wrap checked exceptions
    // into runtime exceptions because we do not expect to run into them. if we do, then it truly is an exception.

    public static Object access(Object obj, String fieldName) {
        return access(obj, Object.class, fieldName);
    }

    public static <T> T access(Object obj, Class<T> type, String fieldName) {
        try {
            Field field = findField(obj, fieldName);
            return type.cast(field.get(obj));
        } catch (IllegalAccessException e) {
            throw new RuntimeException("Unexpected error while accessing " +
                    "\"" + fieldName + "\" from a \"" + obj.getClass().getName() + "\"", e);
        }
    }

    public static void tamper(Object obj, String fieldName, Object newValue) {
        Field field = findField(obj, fieldName);

        // check if the field is final; if it is, then we need to employ a hack to get around this one...
        if ((field.getModifiers() & Modifier.FINAL) != 0) {
            try {
                // work around for the fact that modifiers is now final when inspecting via a Field obtained from
                // getDeclaredField, where as for some reason the Field objects from the internal getDeclaredFields0
                // do not have the same finality. please don't patch this, or at least provide a jvm flag...
                Method getDeclaredFields0 = Class.class.getDeclaredMethod("getDeclaredFields0", boolean.class);
                getDeclaredFields0.setAccessible(true);

                Field[] allFields = (Field[])getDeclaredFields0.invoke(Field.class, false);
                boolean found = false;
                for (Field internalField : allFields) {
                    if (internalField.getName().equals("modifiers")) {
                        internalField.setAccessible(true);
                        internalField.set(field, field.getModifiers() & ~Modifier.FINAL);
                        found = true;
                        break;
                    }
                }

                if (!found) {
                    throw new IllegalStateException("Wasn't able to find \"modifiers\" field! Weird JVM?");
                }
            } catch (NoSuchMethodException exc) {
                throw new IllegalStateException("JVM doesn't have getDeclaredFields0!", exc);
            } catch (InvocationTargetException | IllegalAccessException e) {
                throw new RuntimeException("Unexpected error while trying to bypass final state!", e);
            }
        }

        try {
            field.set(obj, newValue);
        } catch (IllegalAccessException exc) {
            throw new IllegalStateException("setAccessible failed?", exc);
        }
    }

    public static <T, P1, P2> T create(Class<T> klass, Class<P1> param1Type, Class<P2> param2Type, P1 param1, P2 param2) {
        try {
            Constructor<T> ctor = klass.getDeclaredConstructor(param1Type, param2Type);
            ctor.setAccessible(true);
            return ctor.newInstance(param1, param2);
        } catch (NoSuchMethodException exc) {
            throw new IllegalStateException("Constructor wasn't found - unsupported version of Minecraft?", exc);
        } catch (InvocationTargetException | InstantiationException | IllegalAccessException e) {
            throw new RuntimeException("Unexpected error while creating \"" + klass.getName() + "\"", e);
        }
    }

    private static Field findField(Object obj, String fieldName) {
        try {
            Field field = obj.getClass().getDeclaredField(fieldName);
            field.setAccessible(true);
            return field;
        } catch (NoSuchFieldException exc) {
            throw new IllegalStateException("Field wasn't found - unsupported version of Minecraft?", exc);
        }
    }

}
