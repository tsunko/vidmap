package academy.hekiyou.vidmap;

import com.sun.net.httpserver.HttpServer;
import io.netty.channel.*;
import io.netty.channel.socket.DefaultSocketChannelConfig;
import io.netty.channel.socket.SocketChannelConfig;
import it.unimi.dsi.fastutil.objects.Object2IntMap;
import net.minecraft.network.EnumProtocol;
import net.minecraft.network.NetworkManager;
import net.minecraft.network.protocol.EnumProtocolDirection;
import net.minecraft.network.protocol.Packet;
import net.minecraft.network.protocol.game.PacketPlayOutMap;
import org.bukkit.Bukkit;
import org.bukkit.ChatColor;
import org.bukkit.command.Command;
import org.bukkit.command.CommandSender;
import org.bukkit.craftbukkit.v1_17_R1.entity.CraftPlayer;
import org.bukkit.entity.Player;
import org.bukkit.event.EventHandler;
import org.bukkit.event.Listener;
import org.bukkit.event.player.PlayerResourcePackStatusEvent;
import org.bukkit.map.MapRenderer;
import org.bukkit.map.MapView;
import org.bukkit.plugin.java.JavaPlugin;
import org.jetbrains.annotations.NotNull;

import java.io.ByteArrayOutputStream;
import java.io.FileInputStream;
import java.io.IOException;
import java.io.OutputStream;
import java.lang.reflect.Field;
import java.net.InetSocketAddress;
import java.nio.ByteBuffer;
import java.nio.charset.StandardCharsets;
import java.security.MessageDigest;
import java.security.NoSuchAlgorithmException;
import java.util.*;
import java.util.concurrent.Executors;
import java.util.concurrent.Future;
import java.util.concurrent.ScheduledExecutorService;
import java.util.concurrent.TimeUnit;
import java.util.concurrent.atomic.AtomicBoolean;
import java.util.zip.ZipEntry;
import java.util.zip.ZipOutputStream;

public class VidmapPlugin extends JavaPlugin implements Listener {

    private static final String AUDIO_FILENAME = "audio.ogg";
    private static final String INGAME_AUDIO_NAME = "minecraft:vidmap_music";
    private static final int MAP_BYTE_SIZE = 128 * 128;

    private final AtomicBoolean pluginRunning = new AtomicBoolean(true);
    private final ScheduledExecutorService threadPool =
            Executors.newScheduledThreadPool(Runtime.getRuntime().availableProcessors()/2);

    private final Map<Player, Future<?>> running = Collections.synchronizedMap(new WeakHashMap<>());
    private final Map<Player, Runnable> awaiting = new WeakHashMap<>();
    private HttpServer resourcePackServer;
    private byte[] resourcePack;

    @Override
    public void onEnable() {
        System.loadLibrary("nativemap");
        NativeMap.initialize();
        Bukkit.getServer().getPluginManager().registerEvents(this ,this);

        try {
            addPacket();
        } catch (NoSuchFieldException | IllegalAccessException e) {
            throw new IllegalStateException("unable to inject packet");
        }

        try {
            resourcePackServer = HttpServer.create();
            resourcePackServer.bind(new InetSocketAddress("0.0.0.0", 8080), 0);
            resourcePackServer.createContext("/get-pack", exchange -> {
                // unlikely to happen, but handle it just in case
                if(resourcePack == null){
                    exchange.sendResponseHeaders(404, 0);
                    return;
                }

                exchange.sendResponseHeaders(200, resourcePack.length);
                OutputStream os = exchange.getResponseBody();
                os.write(resourcePack);
                os.flush();
                os.close();
            });
            resourcePackServer.start();
        } catch (IOException exc){
            throw new IllegalStateException("failed to startup HTTP server");
        }
    }

    @Override
    public void onDisable(){
        pluginRunning.set(false);
        resourcePackServer.stop(0);
        threadPool.shutdown();
        try {
            if(!threadPool.awaitTermination(5, TimeUnit.MINUTES)){
                throw new IllegalStateException("Waited 5 minutes - thread is probably stuck!");
            }
        } catch (InterruptedException e) {
            // if we reach here, then 5 minutes are up or spurious wake up - either way,
            // we're crashing and burning because NativeMap will kill the server
            throw new IllegalStateException("lp0 on fire!");
        }
        NativeMap.deinitialize();
    }

    @Override
    public boolean onCommand(@NotNull CommandSender sender, @NotNull Command command, @NotNull String label, @NotNull String[] args) {
        // all commands require a player, so just check here /shrug
        if (!(sender instanceof Player player)) {
            sender.sendMessage(ChatColor.RED + "Command requires a player.");
            return true;
        }

        if ("do-video".equalsIgnoreCase(command.getName())) {
            Future<?> existing = running.get(player);
            if(existing != null){
                existing.cancel(false);
                sender.sendMessage(ChatColor.GREEN + "Stopped a video you had active!");
            }

            String source = "C:\\Users\\tsunko\\Desktop\\nativemap\\sample\\" + args[2];

            // submit to our thread pool so we don't end up doing extractAudio on the main thread
            // extractAudio actually takes a bit of time since it's both extracting and transcoding the audio to vorbis
            threadPool.execute(() -> {
                if(!NativeMap.extractAudio(source, AUDIO_FILENAME)){
                    sender.sendMessage(ChatColor.RED + "Failed to extract audio!");
                    return;
                }

                try {
                    resourcePack = generateResourcePack();
                } catch (IOException exc){
                    sender.sendMessage(ChatColor.RED + "Failed to generate resource pack.");
                    exc.printStackTrace();
                    return;
                }

                // do callback to main thread to set resource pack
                Bukkit.getScheduler().scheduleSyncDelayedTask(VidmapPlugin.this, () -> {
                    // okay - this looks weird, but apparently when the client already has a resource pack with a mis-matched
                    // hash, the first invocation just deletes the resource pack? it doesn't make any attempt to replace it
                    // therefore, it's necessary to do a second setResourcePack request
                    String hash = getSHA1Hash(resourcePack);
                    player.setResourcePack("http://localhost:8080/get-pack", hash);
                    Bukkit.getScheduler().scheduleSyncDelayedTask(this, () ->
                            player.setResourcePack("http://localhost:8080/get-pack", hash));
                });
            });

            // put our psuedo-callback in to trigger when the user accepts the resource pack
            awaiting.put(player, () -> {
                int startId = 0;
                int mapW = Integer.parseInt(args[0]);
                int mapH = Integer.parseInt(args[1]);
                int mapCount = mapW * mapH;

                ByteBuffer buffer = ByteBuffer.allocateDirect(mapCount * MAP_BYTE_SIZE);
                long fbfPtr = NativeMap.createFBF(buffer, mapW, mapH);
                double frameDelay = NativeMap.setupFBF(fbfPtr, source);

                if (frameDelay == -1.0) {
                    sender.sendMessage(ChatColor.RED + "Failed to initialize FBF context.");
                    NativeMap.freeFBF(fbfPtr);
                    return;
                }

                clearRenderersForMaps(startId, mapCount);

                ReusableMapPacket[] packets = getPacketsFor(startId, buffer, mapCount);
                NativeMapRenderFrameTask task = new NativeMapRenderFrameTask(player, fbfPtr, packets);
                Future<?> future = threadPool.scheduleAtFixedRate(task, (long)(frameDelay * 1000), (long)(frameDelay * 1000), TimeUnit.MICROSECONDS);
                task.setSelf(future);

                running.put(player, future);
                sender.sendMessage(ChatColor.GREEN + "Wao");
            });

            sender.sendMessage(ChatColor.YELLOW + "Waiting for texture pack install...");
            return true;
        } else if("stop-video".equals(command.getName())){
            Future<?> future = running.get(player);
            if(future != null){
                future.cancel(false);
                sender.sendMessage(ChatColor.GREEN + "Attempted to stop video. Note: video may still play for a bit.");
            } else {
                sender.sendMessage(ChatColor.RED + "No active video playing.");
            }
        }

        return false;
    }

    @EventHandler
    public void listenForResourcePack(PlayerResourcePackStatusEvent event){
        Player player = event.getPlayer();
        switch (event.getStatus()) {
            case DECLINED ->
                player.sendMessage(ChatColor.RED + "Declined resource pack - not running.");
            case ACCEPTED ->
                player.sendMessage(ChatColor.YELLOW + "Accepted resource pack - waiting for load event...");
            case FAILED_DOWNLOAD ->
                player.sendMessage(ChatColor.YELLOW + "Client said download failed - normal if first time.");
            case SUCCESSFULLY_LOADED -> {
                Runnable task = awaiting.remove(event.getPlayer());
                if(task == null) {
                    player.sendMessage(ChatColor.RED + "Null task - try command again?");
                    return;
                }
                task.run();
            }
        }
    }

    private byte[] generateResourcePack() throws IOException {
        ByteArrayOutputStream baos = new ByteArrayOutputStream();
        ZipOutputStream zip = new ZipOutputStream(baos);

        ZipEntry mcMeta = new ZipEntry("pack.mcmeta");
        {
            zip.putNextEntry(mcMeta);
            zip.write("{\"pack\":{\"pack_format\":7, \"description\": \"VidMap Sound Pack\"}}"
                    .getBytes(StandardCharsets.UTF_8));
            zip.closeEntry();
        }

        ZipEntry music = new ZipEntry("assets/minecraft/sounds/vidmap/vidmap_music.ogg");
        {
            zip.putNextEntry(music);
            byte[] buffer = new byte[8192];
            FileInputStream fis = new FileInputStream(AUDIO_FILENAME);
            int read;
            while((read = fis.read(buffer)) != -1){
                zip.write(buffer, 0, read);
            }
            fis.close();
            zip.closeEntry();
        }

        ZipEntry soundsJson = new ZipEntry("assets/minecraft/sounds.json");
        {
            zip.putNextEntry(soundsJson);
            // explicitly state stream=true so minecraft doesn't load the entire sound file at once
            zip.write("{\"vidmap_music\":{\"sounds\":[{\"name\":\"vidmap/vidmap_music\",\"stream\":true}]}}".getBytes(StandardCharsets.UTF_8));
            zip.closeEntry();
        }

        zip.close();
        return baos.toByteArray();
    }

    private static String getSHA1Hash(byte[] bytes) {
        MessageDigest md;
        try {
            md = MessageDigest.getInstance("SHA-1");
        } catch(NoSuchAlgorithmException e) {
            e.printStackTrace();
            return "";
        }
        return toHex(md.digest(bytes));
    }

    private static String toHex(byte[] b) {
        StringBuilder result = new StringBuilder();
        for (byte value : b) {
            result.append(Integer.toString((value & 0xff) + 0x100, 16).substring(1));
        }
        return result.toString();
    }

    private ReusableMapPacket[] getPacketsFor(int start, ByteBuffer source, int mapCount){
        List<ReusableMapPacket> packets = new ArrayList<>();
        for(int i=0; i < mapCount; i++) {
            ByteBuffer slice = source.slice(i * MAP_BYTE_SIZE, MAP_BYTE_SIZE);
            packets.add(new ReusableMapPacket(start + i, slice));
        }
        return packets.toArray(new ReusableMapPacket[0]);
    }

    private void clearRenderersForMaps(int start, int count){
        for(int i=0; i < count; i++){
            MapView view = Bukkit.getMap(start + i);
            if(view == null) throw new IllegalStateException("Failed to get map view for ID " + (start + i));
            List<MapRenderer> rendererCopy = new ArrayList<>(view.getRenderers());
            for(MapRenderer renderer : rendererCopy)
                view.removeRenderer(renderer);
        }
    }

    private static void addPacket() throws NoSuchFieldException, IllegalAccessException {
        // inject our custom packet into the right packet classification
        Map<Class<? extends Packet<?>>, EnumProtocol> classToProto = getField(EnumProtocol.b, "h");
        classToProto.put(ReusableMapPacket.class, EnumProtocol.b);

        // next, we need to inject a custom proxy map so that we can get both the regular and custom map packet
        Map<EnumProtocolDirection, Object> direction = getField(EnumProtocol.b, "j");
        Object enumProtoA = direction.get(EnumProtocolDirection.b);

        // create proxy map and put our packet in
        Object2IntMap<Class<? extends Packet<?>>> delegate = getField(enumProtoA, "a");
        ProxyObject2IntMap<Class<? extends Packet<?>>> map = new ProxyObject2IntMap<>(delegate);
        map.putProxy(ReusableMapPacket.class, delegate.getInt(PacketPlayOutMap.class));

        // set our proxy map as the value so minecraft can use it
        setField(enumProtoA, "a", map);
    }

    private NetworkManager getNetworkManager(Player player){
        return ((CraftPlayer)player).getHandle().networkManager;
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

    public class NativeMapRenderFrameTask implements Runnable {

        private final long ptr;
        private final Player player;
        private final NetworkManager networkManager;
        private final ReusableMapPacket[] packets;
        private boolean playedMusic = false;
        private Future<?> self;

        private NativeMapRenderFrameTask(Player target, long ptr, ReusableMapPacket[] packets){
            this.ptr = ptr;
            this.player = target;
            this.networkManager = getNetworkManager(target);
            this.packets = packets;
        }

        public void setSelf(Future<?> self) {
            this.self = self;
        }

        @Override
        public void run() {
            if (!self.isCancelled() && pluginRunning.get() && NativeMap.stepFBF(ptr)) {
                if(!playedMusic){
                    Bukkit.getScheduler().scheduleSyncDelayedTask(VidmapPlugin.this, () ->
                        player.playSound(player.getLocation(), INGAME_AUDIO_NAME, 2.0f, 1.0f)
                    );
                    playedMusic = true;
                }

                // we directly interact with the network manager, so we have more options
                // this may indirectly lead to some funny errors, but this is the only way we're going to realistically
                // achieve relatively good response times while under high load
                networkManager.clearPacketQueue();
                for (ReusableMapPacket packet : packets) {
                    networkManager.sendPacket(packet);
                }
            } else {
                NativeMap.freeFBF(ptr);
                self.cancel(false);
                running.remove(player);
            }
        }

    }

}
