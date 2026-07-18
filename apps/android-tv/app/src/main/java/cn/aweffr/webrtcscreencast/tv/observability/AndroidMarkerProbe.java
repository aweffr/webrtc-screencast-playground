package cn.aweffr.webrtcscreencast.tv.observability;

import android.graphics.Bitmap;
import android.os.SystemClock;
import java.io.File;
import java.io.FileOutputStream;
import java.io.IOException;
import java.nio.ByteBuffer;
import java.util.HashSet;
import java.util.Locale;
import java.util.Map;
import java.util.Set;
import java.util.concurrent.ExecutorService;
import java.util.concurrent.Executors;
import java.util.concurrent.TimeUnit;
import org.webrtc.VideoFrame;
import org.webrtc.VideoSink;

/** Decodes baseline markers at render callback entry and retains selected decoded PNGs. */
public final class AndroidMarkerProbe implements VideoSink, AutoCloseable {
  private static final int GRID_SIZE = 12;
  private static final int VERSION = 1;
  private static final int[][] MARKER_ROIS = {{64, 64, 192}, {195, 103, 217}};
  private static final Set<Integer> PNG_SEQUENCES =
      Set.of(1, 2, 3, 4, 5, 6, 7, 8, 30, 80, 130);

  public record Marker(int version, int sequence) {}

  static boolean retainsPngForSequence(int sequence) {
    return PNG_SEQUENCES.contains(sequence);
  }

  public static final class MarkerException extends IllegalArgumentException {
    public MarkerException(String message) {
      super(message);
    }
  }

  private final ReceiverMetricsRecorder recorder;
  private final ClockCalibration calibration;
  private final Set<Integer> observedSequences = new HashSet<>();
  private final ActiveWindowGapTracker activeGapTracker = new ActiveWindowGapTracker();
  private final ExecutorService imageExecutor = Executors.newSingleThreadExecutor(runnable -> {
    Thread thread = new Thread(runnable, "receiver-baseline-image");
    thread.setDaemon(true);
    return thread;
  });

  public AndroidMarkerProbe(
      ReceiverMetricsRecorder recorder,
      ClockCalibration calibration) {
    this.recorder = recorder;
    this.calibration = calibration;
  }

  @Override
  public synchronized void onFrame(VideoFrame frame) {
    long renderEntryNs = SystemClock.elapsedRealtimeNanos();
    VideoFrame.I420Buffer i420 = frame.getBuffer().toI420();
    try {
      Marker marker = decodeLumaBufferAtCandidateRois(
          i420.getDataY(),
          i420.getWidth(),
          i420.getHeight(),
          i420.getStrideY(),
          MARKER_ROIS);
      activeGapTracker.observe(marker.sequence(), renderEntryNs);
      if (!observedSequences.add(marker.sequence())) {
        return;
      }
      recorder.record("baseline_android_render_detected", Map.of(
          "marker_version", marker.version(),
          "sequence", marker.sequence(),
          "local_monotonic_ns", renderEntryNs,
          "common_time_ns", calibration.toCommonTimeNs(renderEntryNs),
          "frame_width", i420.getWidth(),
          "frame_height", i420.getHeight(),
          "rotation", frame.getRotation()));
      if (retainsPngForSequence(marker.sequence())) {
        i420.retain();
        imageExecutor.execute(() -> writePng(marker.sequence(), i420));
      }
    } catch (MarkerException | ArithmeticException ignored) {
      // Ordinary content is not a marker; malformed/uncalibrated frames are not evidence.
    } finally {
      i420.release();
    }
  }

  private void writePng(int sequence, VideoFrame.I420Buffer buffer) {
    String fileName = String.format(Locale.ROOT, "android-decoded-seq-%06d.png", sequence);
    File output = new File(recorder.directory(), fileName);
    try {
      int width = buffer.getWidth();
      int height = buffer.getHeight();
      int[] pixels = toArgb(buffer);
      Bitmap bitmap = Bitmap.createBitmap(width, height, Bitmap.Config.ARGB_8888);
      bitmap.setPixels(pixels, 0, width, 0, 0, width, height);
      try (FileOutputStream stream = new FileOutputStream(output)) {
        if (!bitmap.compress(Bitmap.CompressFormat.PNG, 100, stream)) {
          throw new IOException("Bitmap PNG compression failed");
        }
      } finally {
        bitmap.recycle();
      }
      recorder.record("baseline_android_png_written", Map.of(
          "sequence", sequence,
          "file_name", fileName,
          "frame_width", width,
          "frame_height", height));
    } catch (IOException | RuntimeException error) {
      recorder.record("baseline_android_png_failed", Map.of(
          "sequence", sequence,
          "error_type", error.getClass().getSimpleName()));
    } finally {
      buffer.release();
    }
  }

  private static int[] toArgb(VideoFrame.I420Buffer buffer) {
    int width = buffer.getWidth();
    int height = buffer.getHeight();
    int[] pixels = new int[width * height];
    ByteBuffer yPlane = buffer.getDataY();
    ByteBuffer uPlane = buffer.getDataU();
    ByteBuffer vPlane = buffer.getDataV();
    int yBase = yPlane.position();
    int uBase = uPlane.position();
    int vBase = vPlane.position();
    int strideY = buffer.getStrideY();
    int strideU = buffer.getStrideU();
    int strideV = buffer.getStrideV();
    for (int y = 0; y < height; y++) {
      for (int x = 0; x < width; x++) {
        int luminance = (yPlane.get(yBase + y * strideY + x) & 0xff) - 16;
        int u = (uPlane.get(uBase + (y / 2) * strideU + x / 2) & 0xff) - 128;
        int v = (vPlane.get(vBase + (y / 2) * strideV + x / 2) & 0xff) - 128;
        int c = Math.max(0, luminance);
        int red = clip((298 * c + 409 * v + 128) >> 8);
        int green = clip((298 * c - 100 * u - 208 * v + 128) >> 8);
        int blue = clip((298 * c + 516 * u + 128) >> 8);
        pixels[y * width + x] = 0xff000000 | red << 16 | green << 8 | blue;
      }
    }
    return pixels;
  }

  static final class ActiveWindowGapTracker {
    private static final long WINDOW_NS = 1_000_000_000L;
    private int currentSequence = -1;
    private long windowStartNs;
    private long previousFrameNs;
    private long lastObservedFrameNs;
    private long maxFrameGapNs;
    private int windowCount;
    private int frameCount;
    private boolean windowOpen;

    record Snapshot(int windowCount, int frameCount, long maxFrameGapNs) {}

    void observe(int sequence, long frameNs) {
      if (sequence == currentSequence) {
        if (windowOpen) {
          recordActiveFrame(frameNs);
        }
        lastObservedFrameNs = frameNs;
        return;
      }

      if (windowOpen) {
        finishWindow(frameNs);
      }
      long priorFrameNs = lastObservedFrameNs;
      currentSequence = sequence;
      lastObservedFrameNs = frameNs;
      if (sequence < 2 || sequence > 7) {
        return;
      }

      windowStartNs = frameNs;
      previousFrameNs = frameNs;
      windowOpen = true;
      windowCount++;
      frameCount++;
      if (priorFrameNs != 0) {
        maxFrameGapNs = Math.max(maxFrameGapNs, frameNs - priorFrameNs);
      }
    }

    Snapshot snapshot() {
      return new Snapshot(windowCount, frameCount, maxFrameGapNs);
    }

    Snapshot snapshot(long observationEndNs) {
      if (windowOpen) {
        finishWindow(observationEndNs);
      }
      return snapshot();
    }

    private void recordActiveFrame(long frameNs) {
      long windowEndNs = windowStartNs + WINDOW_NS;
      if (frameNs > windowEndNs) {
        finishWindow(frameNs);
        return;
      }
      maxFrameGapNs = Math.max(maxFrameGapNs, frameNs - previousFrameNs);
      previousFrameNs = frameNs;
      frameCount++;
    }

    private void finishWindow(long observationEndNs) {
      long measuredEndNs = Math.min(observationEndNs, windowStartNs + WINDOW_NS);
      maxFrameGapNs = Math.max(maxFrameGapNs, measuredEndNs - previousFrameNs);
      windowOpen = false;
    }
  }

  private static int clip(int value) {
    return Math.max(0, Math.min(255, value));
  }

  public static Marker decodeLuma(
      byte[] luma,
      int width,
      int height,
      int stride,
      int left,
      int top,
      int size) {
    if (luma == null
        || width <= 0
        || height <= 0
        || stride < width
        || luma.length < stride * height
        || left < 0
        || top < 0
        || size < GRID_SIZE
        || left + size > width
        || top + size > height) {
      throw new MarkerException("invalid marker dimensions");
    }
    return decodeSamples(
        index -> luma[index] & 0xff,
        width,
        height,
        stride,
        left,
        top,
        size);
  }

  static Marker decodeLumaAtCandidateRois(
      byte[] luma,
      int width,
      int height,
      int stride,
      int[][] candidates) {
    MarkerException lastError = new MarkerException("no marker ROI candidates");
    for (int[] roi : candidates) {
      try {
        return decodeLuma(luma, width, height, stride, roi[0], roi[1], roi[2]);
      } catch (MarkerException error) {
        lastError = error;
      }
    }
    throw lastError;
  }

  private static Marker decodeLumaBufferAtCandidateRois(
      ByteBuffer luma,
      int width,
      int height,
      int stride,
      int[][] candidates) {
    MarkerException lastError = new MarkerException("no marker ROI candidates");
    for (int[] roi : candidates) {
      try {
        return decodeLumaBuffer(luma, width, height, stride, roi[0], roi[1], roi[2]);
      } catch (MarkerException error) {
        lastError = error;
      }
    }
    throw lastError;
  }

  private static Marker decodeLumaBuffer(
      ByteBuffer luma,
      int width,
      int height,
      int stride,
      int left,
      int top,
      int size) {
    if (luma == null
        || width <= 0
        || height <= 0
        || stride < width
        || left < 0
        || top < 0
        || size < GRID_SIZE
        || left + size > width
        || top + size > height
        || luma.remaining() < stride * height) {
      throw new MarkerException("invalid marker buffer");
    }
    ByteBuffer samples = luma.duplicate();
    int base = samples.position();
    return decodeSamples(
        index -> samples.get(base + index) & 0xff,
        width,
        height,
        stride,
        left,
        top,
        size);
  }

  private interface LumaSamples {
    int get(int index);
  }

  private static Marker decodeSamples(
      LumaSamples luma,
      int width,
      int height,
      int stride,
      int left,
      int top,
      int size) {
    boolean[] cells = new boolean[GRID_SIZE * GRID_SIZE];
    for (int y = 0; y < GRID_SIZE; y++) {
      for (int x = 0; x < GRID_SIZE; x++) {
        int sampleX = left + (int) ((x + 0.5) * size / GRID_SIZE);
        int sampleY = top + (int) ((y + 0.5) * size / GRID_SIZE);
        cells[y * GRID_SIZE + x] = luma.get(sampleY * stride + sampleX) < 128;
      }
    }
    verifyFinder(cells);

    byte[] encoded = new byte[7];
    for (int bit = 0; bit < encoded.length * 8; bit++) {
      int cellX = 1 + bit % 10;
      int cellY = 1 + bit / 10;
      if (cells[cellY * GRID_SIZE + cellX]) {
        encoded[bit / 8] |= (byte) (1 << (7 - bit % 8));
      }
    }
    int expectedCrc = ((encoded[5] & 0xff) << 8) | (encoded[6] & 0xff);
    if (crc16(encoded, 5) != expectedCrc) {
      throw new MarkerException("marker checksum mismatch");
    }
    int version = encoded[0] & 0xff;
    if (version != VERSION) {
      throw new MarkerException("unsupported marker version: " + version);
    }
    int sequence = ((encoded[1] & 0xff) << 24)
        | ((encoded[2] & 0xff) << 16)
        | ((encoded[3] & 0xff) << 8)
        | (encoded[4] & 0xff);
    return new Marker(version, sequence);
  }

  private static void verifyFinder(boolean[] cells) {
    for (int y = 0; y < GRID_SIZE; y++) {
      for (int x = 0; x < GRID_SIZE; x++) {
        if ((x == 0 || y == 0 || x == GRID_SIZE - 1 || y == GRID_SIZE - 1)
            && cells[y * GRID_SIZE + x] != finderValue(x, y)) {
          throw new MarkerException("marker finder mismatch");
        }
      }
    }
  }

  private static boolean finderValue(int x, int y) {
    if (y == 0) {
      return x % 2 == 0;
    }
    if (x == GRID_SIZE - 1) {
      return y % 2 == 0;
    }
    if (y == GRID_SIZE - 1) {
      return x % 2 != 0;
    }
    return y % 2 != 0;
  }

  private static int crc16(byte[] bytes, int count) {
    int crc = 0xffff;
    for (int index = 0; index < count; index++) {
      crc ^= (bytes[index] & 0xff) << 8;
      for (int bit = 0; bit < 8; bit++) {
        crc = (crc & 0x8000) != 0 ? (crc << 1) ^ 0x1021 : crc << 1;
        crc &= 0xffff;
      }
    }
    return crc;
  }

  @Override
  public synchronized void close() {
    ActiveWindowGapTracker.Snapshot gap =
        activeGapTracker.snapshot(SystemClock.elapsedRealtimeNanos());
    recorder.record("baseline_android_active_gap_summary", Map.of(
        "active_window_count", gap.windowCount(),
        "active_frame_count", gap.frameCount(),
        "max_frame_gap_ms", gap.maxFrameGapNs() / 1_000_000.0));
    imageExecutor.shutdown();
    try {
      if (!imageExecutor.awaitTermination(10, TimeUnit.SECONDS)) {
        imageExecutor.shutdownNow();
      }
    } catch (InterruptedException error) {
      Thread.currentThread().interrupt();
      imageExecutor.shutdownNow();
    }
  }
}
