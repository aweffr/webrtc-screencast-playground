package cn.aweffr.webrtcscreencast.tv.observability;

import android.content.Context;
import android.os.SystemClock;
import java.io.BufferedWriter;
import java.io.File;
import java.io.FileWriter;
import java.io.IOException;
import java.time.Instant;
import java.util.Locale;
import java.util.Map;
import java.util.Objects;
import java.util.UUID;
import java.util.concurrent.ExecutorService;
import java.util.concurrent.Executors;
import java.util.concurrent.TimeUnit;
import java.util.concurrent.atomic.AtomicBoolean;
import org.json.JSONException;
import org.json.JSONObject;

/** Serial JSONL evidence writer that rejects sensitive negotiation fields by contract. */
public final class ReceiverMetricsRecorder implements AutoCloseable {
  private final String runId;
  private final File directory;
  private final BufferedWriter writer;
  private final ExecutorService executor = Executors.newSingleThreadExecutor(runnable -> {
    Thread thread = new Thread(runnable, "receiver-evidence");
    thread.setDaemon(true);
    return thread;
  });
  private final AtomicBoolean closed = new AtomicBoolean();

  public ReceiverMetricsRecorder(Context context) throws IOException {
    this(context, UUID.randomUUID().toString().toLowerCase(Locale.ROOT));
  }

  ReceiverMetricsRecorder(Context context, String runId) throws IOException {
    this.runId = Objects.requireNonNull(runId, "runId");
    directory = new File(context.getFilesDir(), "evidence/" + runId);
    if (!directory.mkdirs() && !directory.isDirectory()) {
      throw new IOException("Unable to create receiver evidence directory");
    }
    writer = new BufferedWriter(new FileWriter(new File(directory, "receiver.jsonl"), true));
  }

  public String runId() {
    return runId;
  }

  public File directory() {
    return directory;
  }

  public void record(String event) {
    record(event, Map.of());
  }

  public void record(String event, Map<String, ?> fields) {
    Objects.requireNonNull(event, "event");
    Objects.requireNonNull(fields, "fields");
    rejectSensitiveFields(fields);
    if (closed.get()) {
      return;
    }
    long monotonicNs = SystemClock.elapsedRealtimeNanos();
    String wallTime = Instant.now().toString();
    executor.execute(() -> write(event, fields, monotonicNs, wallTime));
  }

  private void write(String event, Map<String, ?> fields, long monotonicNs, String wallTime) {
    try {
      JSONObject record = new JSONObject();
      record.put("schema_version", 1);
      record.put("run_id", runId);
      record.put("wall_time", wallTime);
      record.put("monotonic_ns", monotonicNs);
      record.put("event", event);
      record.put("fields", new JSONObject(fields));
      writer.write(record.toString());
      writer.newLine();
      writer.flush();
    } catch (IOException | JSONException error) {
      throw new IllegalStateException("Unable to write receiver evidence", error);
    }
  }

  private static void rejectSensitiveFields(Map<String, ?> fields) {
    for (String key : fields.keySet()) {
      String normalized = key.toLowerCase(Locale.ROOT);
      if (normalized.contains("sdp")
          || normalized.contains("candidate")
          || normalized.contains("credential")
          || normalized.contains("password")
          || normalized.contains("pairing_code")) {
        throw new IllegalArgumentException("Sensitive receiver evidence field: " + key);
      }
    }
  }

  @Override
  public void close() {
    if (!closed.compareAndSet(false, true)) {
      return;
    }
    executor.shutdown();
    try {
      if (!executor.awaitTermination(5, TimeUnit.SECONDS)) {
        executor.shutdownNow();
      }
      writer.close();
    } catch (InterruptedException error) {
      Thread.currentThread().interrupt();
      executor.shutdownNow();
    } catch (IOException error) {
      throw new IllegalStateException("Unable to close receiver evidence", error);
    }
  }
}
