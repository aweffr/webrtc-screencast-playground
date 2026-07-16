package cn.aweffr.webrtcscreencast.tv.observability;

import java.io.BufferedWriter;
import java.io.File;
import java.io.FileOutputStream;
import java.io.IOException;
import java.io.OutputStreamWriter;
import java.nio.charset.StandardCharsets;
import java.util.Objects;
import java.util.regex.Pattern;
import org.json.JSONException;
import org.json.JSONObject;

/** Ephemeral app-private control record used by the single-host E2E harness. */
public final class ReceiverAutomationChannel {
  private static final Pattern PAIRING_CODE =
      Pattern.compile("[0-9A-HJKMNPQRSTVWXYZ]{8}");

  private final File directory;
  private final File file;

  public ReceiverAutomationChannel(File directory) throws IOException {
    this.directory = Objects.requireNonNull(directory, "directory");
    if (!directory.mkdirs() && !directory.isDirectory()) {
      throw new IOException("Unable to create receiver automation directory");
    }
    file = new File(directory, "automation.jsonl");
  }

  public synchronized void publishPairingCode(String sessionId, String pairingCode)
      throws IOException {
    if (sessionId == null || sessionId.trim().isEmpty()) {
      throw new IllegalArgumentException("sessionId is required");
    }
    if (pairingCode == null || !PAIRING_CODE.matcher(pairingCode).matches()) {
      throw new IllegalArgumentException("pairingCode is invalid");
    }
    File temporary = File.createTempFile("automation-", ".tmp", directory);
    try {
      JSONObject record = new JSONObject();
      record.put("event", "receiver_registered");
      record.put("session_id", sessionId);
      record.put("pairing_code", pairingCode);
      try (BufferedWriter writer = new BufferedWriter(new OutputStreamWriter(
          new FileOutputStream(temporary), StandardCharsets.UTF_8))) {
        writer.write(record.toString());
        writer.newLine();
      }
      if (file.exists() && !file.delete()) {
        throw new IOException("Unable to replace receiver automation record");
      }
      if (!temporary.renameTo(file)) {
        throw new IOException("Unable to publish receiver automation record");
      }
    } catch (JSONException error) {
      throw new IOException("Unable to encode receiver automation record", error);
    } finally {
      if (temporary.exists() && !temporary.delete()) {
        temporary.deleteOnExit();
      }
    }
  }

  public synchronized void clear() {
    if (file.exists() && !file.delete()) {
      throw new IllegalStateException("Unable to clear receiver automation record");
    }
  }
}
