package academy.hekiyou.vidmap;

import net.kyori.adventure.text.Component;
import net.kyori.adventure.text.format.NamedTextColor;
import net.minecraft.network.NetworkManager;
import org.bukkit.Bukkit;
import org.bukkit.ChatColor;
import org.bukkit.command.BlockCommandSender;
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

import java.io.IOException;
import java.util.*;
import java.util.concurrent.Executors;
import java.util.concurrent.Future;
import java.util.concurrent.ScheduledExecutorService;
import java.util.concurrent.TimeUnit;
import java.util.concurrent.atomic.AtomicBoolean;
import java.util.stream.Collectors;

public class VidmapPlugin extends JavaPlugin implements Listener {

    private static final String AUDIO_FILENAME = "audio.ogg";
    private static final String INGAME_AUDIO_NAME = "minecraft:vidmap_music";

    private final AtomicBoolean pluginRunning = new AtomicBoolean(true);
    private final ScheduledExecutorService threadPool =
            Executors.newScheduledThreadPool(Runtime.getRuntime().availableProcessors()/2);

    private final Map<CommandSender, Future<?>> running = Collections.synchronizedMap(new WeakHashMap<>());
    private final Map<CommandSender, KickOffTask> awaiting = new WeakHashMap<>();
    private ResourcePackServer resourcePackServer;

    @Override
    public void onEnable() {
        System.loadLibrary("nativemap");
        NativeMap.initialize();
        Bukkit.getServer().getPluginManager().registerEvents(this ,this);

        saveDefaultConfig();

        try {
            MapPacketInjector.addPacket();
        } catch (NoSuchFieldException | IllegalAccessException e) {
            throw new IllegalStateException("unable to inject packet");
        }

        try {
            resourcePackServer = new ResourcePackServer(
                    getConfig().getString("Hostname"),
                    getConfig().getInt("Port")
            );
        } catch (IOException exc){
            throw new IllegalStateException("failed to startup HTTP server");
        }
    }

    @Override
    public void onDisable(){
        pluginRunning.set(false);
        if(resourcePackServer != null)
            resourcePackServer.shutdown();
        threadPool.shutdown();
        try {
            if(!threadPool.awaitTermination(1, TimeUnit.MINUTES)){
                throw new IllegalStateException("Waited a minute - thread is probably stuck!");
            }
        } catch (InterruptedException e) {
            // if we reach here, then 5 minutes are up or spurious wake up - either way,
            // we're crashing and burning because NativeMap will kill the server
            throw new IllegalStateException("lp0 on fire!");
        }
        NativeMap.deinitialize();
    }

    @Override
    public boolean onCommand(@NotNull CommandSender initialSender, @NotNull Command command, @NotNull String label, @NotNull String[] args) {
        // check to see if we're dealing with a command block or a player
        // if it's a command block, replace it with console
        final CommandSender sender;
        if(initialSender instanceof BlockCommandSender){
            sender = Bukkit.getConsoleSender();
        } else {
            sender = initialSender;
        }

        if ("setup-video".equalsIgnoreCase(command.getName())) {
            String source = getDataFolder().getAbsolutePath() + "\\" + args[2];

            // submit to our thread pool so we don't end up doing extractAudio on the main thread
            // extractAudio actually takes a bit of time since it's both extracting and transcoding the audio to vorbis
            threadPool.execute(() -> {
                if(!NativeMap.extractAudio(source, AUDIO_FILENAME)){
                    sender.sendMessage(ChatColor.RED + "Failed to extract audio!");
                    return;
                }

                try {
                    resourcePackServer.processNewAudio();
                } catch (IOException exc){
                    sender.sendMessage(ChatColor.RED + "Failed to generate resource pack.");
                    exc.printStackTrace();
                    return;
                }

                // do callback to main thread to set resource pack
                Bukkit.getScheduler().scheduleSyncDelayedTask(VidmapPlugin.this, () -> {
                    String url = String.format("http://%s:%d/get-pack",
                            resourcePackServer.getHostname(), resourcePackServer.getPort());
                    String hash = resourcePackServer.getHash();

                    // okay - this looks weird, but apparently when the client already has a resource pack with a
                    // mis-matched hash, the first invocation just deletes the resource pack? it doesn't make any
                    // attempt to replace it
                    // therefore, it's necessary to do a second setResourcePack request
                    for(Player player : Bukkit.getOnlinePlayers()) {
                        player.setResourcePack(url, hash);
                        Bukkit.getScheduler().scheduleSyncDelayedTask(this, () ->
                                player.setResourcePack(url, hash));
                    }
                });
            });

            // put our psuedo-callback in to trigger when the user accepts the resource pack
            awaiting.put(sender, new KickOffTask(source, Integer.parseInt(args[0]), Integer.parseInt(args[1])));
            sender.sendMessage(ChatColor.YELLOW + "Waiting for texture pack install...");
            return true;
        } else if("stop-video".equals(command.getName())){
            Future<?> future = running.remove(sender);
            if(future != null){
                future.cancel(false);
                sender.sendMessage(ChatColor.GREEN + "Attempted to stop video. Note: video may still play for a bit.");
            } else {
                sender.sendMessage(ChatColor.RED + "No active video playing.");
            }
            return true;
        } else if("start-video".equals(command.getName())){
            KickOffTask task = awaiting.remove(sender);
            if(task == null) {
                sender.sendMessage(ChatColor.RED + "Null task - try command again?");
                return true;
            }
            task.run();
            if(task.wasSuccessful()) {
                running.put(sender, task.getFuture());
                sender.sendMessage(ChatColor.GREEN + "Wao");
            }
            return true;
        } else if("restart-video".equals(command.getName())){
            String source = getDataFolder().getAbsolutePath() + "\\" + args[2];
            KickOffTask task = new KickOffTask(source, Integer.parseInt(args[0]), Integer.parseInt(args[1]));
            task.run();
            if(task.wasSuccessful()) {
                running.put(sender, task.getFuture());
                sender.sendMessage(ChatColor.GREEN + "Restarted video.");
            }
            return true;
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
            case SUCCESSFULLY_LOADED ->
                    Bukkit.getServer().sendMessage(
                            Component
                                    .text(player.getName(), NamedTextColor.GREEN)
                                    .append(
                                            Component.text(" successfully loaded the resource pack.")
                                    )
                    );
        }
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

    private static NetworkManager getNetworkManager(Player player){
        return ((CraftPlayer)player).getHandle().networkManager;
    }

    public class KickOffTask implements Runnable {

        private final String source;
        private final int mapW, mapH;

        private boolean success = false;
        private Future<?> future;

        public KickOffTask(String source, int width, int height){
            this.source = source;
            this.mapW = width;
            this.mapH = height;
        }

        @Override
        public void run() {
            int startMapId = 0;
            int mapCount = mapW * mapH;

            NativeMap map = new NativeMap(mapW, mapH);
            double frameDelay = map.open(source);
            System.out.println("framedelay=" + frameDelay);
            if (frameDelay == -1.0) {
                System.out.println("got negative framedelay");
                map.free();
                return;
            }
            // convert from milliseconds to microseconds for a little more accuracy
            long microFrameDelay = (long)(frameDelay * 1000);

            clearRenderersForMaps(startMapId, mapCount);

            NativeMapRenderFrameTask task = new NativeMapRenderFrameTask(Bukkit.getOnlinePlayers(), map);
            future = threadPool.scheduleAtFixedRate(task, microFrameDelay, microFrameDelay, TimeUnit.MICROSECONDS);
            task.setSelf(future);

            success = true;
            System.out.println("we did it reddit");
        }

        public boolean wasSuccessful() {
            return success;
        }

        public Future<?> getFuture() {
            return future;
        }

    }

    public class NativeMapRenderFrameTask implements Runnable {

        private final NativeMap map;
        private final Collection<? extends Player> players;
        private final List<NetworkManager> networkManagers;
        private boolean playedMusic = false;
        private Future<?> self;

        private NativeMapRenderFrameTask(Collection<? extends Player> targets, NativeMap map){
            this.map = map;
            this.players = targets;
            this.networkManagers = targets.stream().map(VidmapPlugin::getNetworkManager).collect(Collectors.toList());
        }

        public void setSelf(Future<?> self) {
            this.self = self;
        }

        @Override
        public void run() {
            if (!self.isCancelled() && pluginRunning.get() && map.processNextFrame()) {
                if(!playedMusic){
                    for(Player player : players) {
                        Bukkit.getScheduler().scheduleSyncDelayedTask(VidmapPlugin.this, () ->
                                player.playSound(player.getLocation(), INGAME_AUDIO_NAME, 2.0f, 1.0f)
                        );
                    }
                    playedMusic = true;
                }

                // we directly interact with the network manager, so we have more options
                // this may indirectly lead to some funny errors, but this is the only way we're going to realistically
                // achieve relatively good response times while under high load

                for(NetworkManager networkManager : networkManagers) {
                    networkManager.clearPacketQueue();
                    for (PacketPlayOutBufferBackedMap packet : map.getPackets()) {
                        networkManager.sendPacket(packet);
                    }
                }
            } else {
                map.free();
                self.cancel(false);

                for(Player player : players)
                    running.remove(player);
            }
        }

    }

}
