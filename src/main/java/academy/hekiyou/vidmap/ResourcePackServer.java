package academy.hekiyou.vidmap;

import com.sun.net.httpserver.HttpExchange;
import com.sun.net.httpserver.HttpServer;

import java.io.ByteArrayOutputStream;
import java.io.FileInputStream;
import java.io.IOException;
import java.io.OutputStream;
import java.net.InetSocketAddress;
import java.nio.charset.StandardCharsets;
import java.security.MessageDigest;
import java.security.NoSuchAlgorithmException;
import java.util.zip.ZipEntry;
import java.util.zip.ZipOutputStream;

public class ResourcePackServer {

    private static final String AUDIO_FILENAME = "audio.ogg";

    private final String hostname;
    private final int port;

    private final HttpServer httpServer;
    private byte[] resourcePackData;
    private String hash;

    public ResourcePackServer(String h, int p) throws IOException {
        hostname = h;
        port = p;

        httpServer = HttpServer.create();
        httpServer.bind(new InetSocketAddress(h, p), 0);
        httpServer.createContext("/get-pack", this::serveResourcePack);
        httpServer.start();
    }

    public String getHostname() {
        return hostname;
    }

    public int getPort() {
        return port;
    }

    public void processNewAudio() throws IOException {
        ByteArrayOutputStream baos = new ByteArrayOutputStream();
        ZipOutputStream zip = new ZipOutputStream(baos);

        ZipEntry mcMeta = new ZipEntry("pack.mcmeta");
        {
            byte[] mcmetaData = """
                                {
                                    "pack": {
                                        "pack_format": 7,
                                        "description": "VidMap Sound Pack"
                                    }
                               }""".getBytes(StandardCharsets.UTF_8);
            zip.putNextEntry(mcMeta);
            zip.write(mcmetaData);
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
            byte[] jsonData = """
                              {
                                  "vidmap_music": {
                                      "sounds": [
                                          {
                                              "name": "vidmap/vidmap_music",
                                              "stream": true
                                          }
                                      ]
                                  }
                              }""".getBytes(StandardCharsets.UTF_8);
            zip.putNextEntry(soundsJson);
            // explicitly state stream=true so minecraft doesn't load the entire sound file at once
            zip.write(jsonData);
            zip.closeEntry();
        }

        zip.close();
        resourcePackData = baos.toByteArray();
        hash = getSHA1Hash(resourcePackData);
    }

    public String getHash() {
        return hash;
    }

    public void shutdown(){
        httpServer.stop(0);
    }

    private void serveResourcePack(HttpExchange exchange) throws IOException {
        if(resourcePackData == null){
            exchange.sendResponseHeaders(404, -1);
            return;
        } else {
            exchange.sendResponseHeaders(200, resourcePackData.length);
            try(OutputStream os = exchange.getResponseBody()){
                os.write(resourcePackData);
            }
        }
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

}
