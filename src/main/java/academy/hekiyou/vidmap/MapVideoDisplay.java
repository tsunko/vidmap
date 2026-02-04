package academy.hekiyou.vidmap;

import org.bukkit.Bukkit;
import org.bukkit.entity.Player;

import java.io.IOException;
import java.lang.foreign.MemorySegment;
import java.nio.file.Path;
import java.util.ArrayList;
import java.util.List;
import java.util.concurrent.Executors;
import java.util.concurrent.ScheduledExecutorService;
import java.util.concurrent.TimeUnit;
import java.util.concurrent.atomic.AtomicBoolean;
import java.util.concurrent.atomic.AtomicInteger;

public class MapVideoDisplay {

    private static final long MINIMUM_DELAY = 3;
    private static final ScheduledExecutorService POOL =
            Executors.newScheduledThreadPool(Runtime.getRuntime().availableProcessors());

    private final AtomicBoolean isRunning = new AtomicBoolean(false);
    private final AtomicInteger adjustOutputRequest = new AtomicInteger(0);

    private final FrameUpdateTask task;
    private final NativeMap backing;

    public MapVideoDisplay(Path videoPath, short mapWidth, short mapHeight) {
        this.backing = new NativeMap(mapWidth, mapHeight);
        this.task = new FrameUpdateTask();

        try {
            this.backing.open(videoPath.toString());
        } catch (IOException e) {
            throw new RuntimeException(e);
        }
    }

    public void start() {
        if (isRunning.compareAndSet(false, true)) {
            POOL.execute(task);
        }
    }

    public void requestAdjustment(short mapWidth, short mapHeight) {
        adjustOutputRequest.set(mapWidth << 16 | mapHeight);
    }

    public boolean isRunning() {
        return isRunning.get();
    }

    public void stop() {
        isRunning.set(false);
    }

    public static void stopPool() {
        POOL.close();
    }

    private class FrameUpdateTask implements Runnable {

        @Override
        public void run() {
            if (!isRunning.get()) {
                backing.close();
                return;
            }

            int packedRequest = adjustOutputRequest.get();
            if (packedRequest != 0 && adjustOutputRequest.compareAndSet(packedRequest, 0)) {
                short mapWidth = (short) (packedRequest >> 16);
                short mapHeight = (short) (packedRequest & 0xFFFF);
                backing.adjustOutput(mapWidth, mapHeight);
            }

            if (!backing.nextFrame()) {
                isRunning.set(false);
                return;
            }

            ClientboundMapBufferedDataPacket[] packets = generatePackets(backing.getMapCount());
            for (Player player : Bukkit.getOnlinePlayers()) {
                PacketUtils.sendPackets(player, packets);
            }

            long ptsDiff = backing.suggestDelay(MINIMUM_DELAY);
            POOL.schedule(this, ptsDiff, TimeUnit.MILLISECONDS);
        }

        private ClientboundMapBufferedDataPacket[] generatePackets(int mapCount) {
            MemorySegment segment = backing.getBuffer();
            List<ClientboundMapBufferedDataPacket> sections = new ArrayList<>();
            for(int i=0; i < mapCount; i++) {
                MemorySegment slice = segment.asSlice((long) i * 128 * 128, 128 * 128);
                sections.add(new ClientboundMapBufferedDataPacket(i, slice));
            }
            return sections.toArray(new ClientboundMapBufferedDataPacket[0]);
        }

    }

}
