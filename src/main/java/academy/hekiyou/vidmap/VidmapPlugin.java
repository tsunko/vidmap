package academy.hekiyou.vidmap;

import com.mojang.brigadier.Command;
import com.mojang.brigadier.Message;
import com.mojang.brigadier.StringReader;
import com.mojang.brigadier.arguments.ArgumentType;
import com.mojang.brigadier.arguments.IntegerArgumentType;
import com.mojang.brigadier.arguments.StringArgumentType;
import com.mojang.brigadier.context.CommandContext;
import com.mojang.brigadier.exceptions.CommandSyntaxException;
import com.mojang.brigadier.exceptions.SimpleCommandExceptionType;
import com.mojang.brigadier.suggestion.Suggestions;
import com.mojang.brigadier.suggestion.SuggestionsBuilder;
import com.mojang.brigadier.tree.LiteralCommandNode;
import io.papermc.paper.command.brigadier.CommandSourceStack;
import io.papermc.paper.command.brigadier.Commands;
import io.papermc.paper.command.brigadier.MessageComponentSerializer;
import io.papermc.paper.command.brigadier.argument.CustomArgumentType;
import io.papermc.paper.plugin.lifecycle.event.types.LifecycleEvents;
import net.kyori.adventure.text.format.NamedTextColor;
import org.bukkit.Bukkit;
import org.bukkit.entity.Player;
import org.bukkit.event.EventHandler;
import org.bukkit.event.Listener;
import org.bukkit.event.player.PlayerJoinEvent;
import org.bukkit.map.MapRenderer;
import org.bukkit.map.MapView;
import org.bukkit.plugin.java.JavaPlugin;
import org.jspecify.annotations.NullMarked;

import java.io.IOException;
import java.nio.file.Files;
import java.nio.file.Path;
import java.util.ArrayList;
import java.util.List;
import java.util.concurrent.CompletableFuture;
import java.util.stream.Stream;

import static net.kyori.adventure.text.Component.text;

public class VidmapPlugin extends JavaPlugin implements Listener {

    private MapVideoDisplay runningDisplay;

    @Override
    public void onEnable() {
        NativeMap.initNativeMap(this.getDataPath().resolve("lut.dat"));

        Path videosPath = this.getDataPath().resolve("videos");
        LiteralCommandNode<CommandSourceStack> root =
                Commands.literal("vidmap")
                        .then(Commands.literal("start")
                                .then(Commands.argument("file", new VideoPathArgument(videosPath))
                                        .then(Commands.argument("mapWidth", IntegerArgumentType.integer(1, 100))
                                                .then(Commands.argument("mapHeight", IntegerArgumentType.integer(1, 100))
                                                        .executes(ctx -> {
                                                            Path videoPath = ctx.getArgument("file", Path.class);
                                                            if (Files.notExists(videoPath)) {
                                                                Message message = MessageComponentSerializer.message().serialize(
                                                                        text("Video file doesn't exist."));
                                                                throw new SimpleCommandExceptionType(message).create();
                                                            }

                                                            if (runningDisplay != null) {
                                                                runningDisplay.stop();
                                                            }

                                                            short width = (short) IntegerArgumentType.getInteger(ctx, "mapWidth");
                                                            short height = (short) IntegerArgumentType.getInteger(ctx, "mapHeight");

                                                            // clear renderers
                                                            for (int i=0; i < width * height; i++) {
                                                                MapView view = Bukkit.getMap(i);
                                                                if (view == null) {
                                                                    Message message = MessageComponentSerializer.message().serialize(
                                                                            text("Failed to get map with ID " + i));
                                                                    throw new SimpleCommandExceptionType(message).create();
                                                                }
                                                                List<MapRenderer> renderers = new ArrayList<>(view.getRenderers());
                                                                for (MapRenderer renderer : renderers) {
                                                                    view.removeRenderer(renderer);
                                                                }
                                                            }

                                                            runningDisplay = new MapVideoDisplay(videoPath, width, height);
                                                            runningDisplay.start();

                                                            return Command.SINGLE_SUCCESS;
                                                        })
                                                ))))
                        .then(Commands.literal("adjust")
                                .then(Commands.argument("mapWidth", IntegerArgumentType.integer(1, 100))
                                        .then(Commands.argument("mapHeight", IntegerArgumentType.integer(1, 100))
                                                .executes(ctx -> {
                                                    ensureRunning();

                                                    short newWidth = (short) IntegerArgumentType.getInteger(ctx, "mapWidth");
                                                    short newHeight = (short) IntegerArgumentType.getInteger(ctx, "mapHeight");

                                                    runningDisplay.requestAdjustment(newWidth, newHeight);

                                                    return Command.SINGLE_SUCCESS;
                                                })
                                        )))
                        .then(Commands.literal("stop")
                                .executes(ctx -> {
                                    ensureRunning();

                                    runningDisplay.stop();

                                    return Command.SINGLE_SUCCESS;
                                })
                        )
                        .build();

        this.getLifecycleManager().registerEventHandler(LifecycleEvents.COMMANDS, commands -> {
            commands.registrar().register(root);
        });

        getServer().getPluginManager().registerEvents(this, this);
    }

    private void ensureRunning() throws CommandSyntaxException {
        if (runningDisplay == null ||!runningDisplay.isRunning()) {
            Message message = MessageComponentSerializer.message().serialize(
                    text("No video is currently playing."));
            throw new SimpleCommandExceptionType(message).create();
        }
    }

    @EventHandler
    public void injectAtLogin(PlayerJoinEvent event) {
        Player player = event.getPlayer();
        PacketUtils.injectPacket(player);
        player.sendMessage(text("Injected custom packet definition.", NamedTextColor.GREEN));
    }

    @Override
    public void onDisable() {
        if (runningDisplay != null && runningDisplay.isRunning()) {
            runningDisplay.stop();
        }
        MapVideoDisplay.stopPool();
    }

    @NullMarked
    private final class VideoPathArgument implements CustomArgumentType<Path, String> {

        private final Path videosPath;

        VideoPathArgument(Path videosPath) {
            this.videosPath = videosPath;
        }

        @Override
        public Path parse(StringReader reader) {
            return videosPath.resolve(reader.readUnquotedString());
        }

        @Override
        public ArgumentType<String> getNativeType() {
            return StringArgumentType.word();
        }

        @Override
        public <S> CompletableFuture<Suggestions> listSuggestions(CommandContext<S> context, SuggestionsBuilder builder) {
            try (Stream<Path> paths = Files.list(videosPath)){
                paths.map(Path::getFileName).map(Path::toString).forEach(builder::suggest);
            } catch (IOException e) {
                throw new RuntimeException(e);
            }
            return builder.buildFuture();
        }

    }

}
