package academy.hekiyou.vidmap;

import it.unimi.dsi.fastutil.objects.Object2IntMap;
import net.minecraft.network.EnumProtocol;
import net.minecraft.network.protocol.EnumProtocolDirection;
import net.minecraft.network.protocol.Packet;
import net.minecraft.network.protocol.game.PacketPlayOutMap;

import java.lang.reflect.Field;
import java.util.Map;

public class MapPacketInjector {

    public static void addPacket() throws NoSuchFieldException, IllegalAccessException {
        // inject our custom packet into the right packet classification
        Map<Class<? extends Packet<?>>, EnumProtocol> classToProto = getField(EnumProtocol.b, "h");
        classToProto.put(PacketPlayOutBufferBackedMap.class, EnumProtocol.b);

        // next, we need to inject a custom proxy map so that we can get both the regular and custom map packet
        Map<EnumProtocolDirection, Object> direction = getField(EnumProtocol.b, "j");
        Object enumProtoA = direction.get(EnumProtocolDirection.b);

        // create proxy map and put our packet in
        Object2IntMap<Class<? extends Packet<?>>> delegate = getField(enumProtoA, "a");
        ProxyObject2IntMap<Class<? extends Packet<?>>> map = new ProxyObject2IntMap<>(delegate);
        map.putProxy(PacketPlayOutBufferBackedMap.class, delegate.getInt(PacketPlayOutMap.class));

        // set our proxy map as the value so minecraft can use it
        setField(enumProtoA, "a", map);
    }

    @SuppressWarnings("unchecked")
    private static <T> T getField(Object instance, String fieldName) throws NoSuchFieldException, IllegalAccessException {
        Field field = instance.getClass().getDeclaredField(fieldName);
        field.setAccessible(true);
        return (T)field.get(instance);
    }

    private static void setField(Object instance, String fieldName, Object value) throws NoSuchFieldException, IllegalAccessException {
        Field field = instance.getClass().getDeclaredField(fieldName);
        field.setAccessible(true);
        field.set(instance, value);
    }


}
