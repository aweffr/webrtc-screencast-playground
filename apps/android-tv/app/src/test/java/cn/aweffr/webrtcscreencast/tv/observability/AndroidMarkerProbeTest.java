package cn.aweffr.webrtcscreencast.tv.observability;

import static org.junit.Assert.assertEquals;
import static org.junit.Assert.assertThrows;
import static org.junit.Assert.assertTrue;

import org.junit.Test;

public final class AndroidMarkerProbeTest {
  @Test
  public void retainsMeetingDocumentPhaseImages() {
    assertTrue(AndroidMarkerProbe.retainsPngForSequence(1));
    assertTrue(AndroidMarkerProbe.retainsPngForSequence(4));
    assertTrue(AndroidMarkerProbe.retainsPngForSequence(8));
  }

  @Test
  public void tracksFrameGapsOnlyInScrollActiveWindows() {
    AndroidMarkerProbe.ActiveWindowGapTracker tracker =
        new AndroidMarkerProbe.ActiveWindowGapTracker();
    tracker.observe(1, 950_000_000L);
    tracker.observe(2, 1_000_000_000L);
    tracker.observe(2, 1_070_000_000L);
    tracker.observe(2, 1_570_000_000L);
    tracker.observe(2, 2_100_000_000L); // Outside the one-second ACTIVE window.
    tracker.observe(2, 5_950_000_000L);
    tracker.observe(3, 6_000_000_000L);
    tracker.observe(3, 6_080_000_000L);

    AndroidMarkerProbe.ActiveWindowGapTracker.Snapshot snapshot = tracker.snapshot();
    assertEquals(2, snapshot.windowCount());
    assertEquals(5, snapshot.frameCount());
    assertEquals(500_000_000L, snapshot.maxFrameGapNs());
  }

  @Test
  public void includesTheGapEnteringAnActiveWindow() {
    AndroidMarkerProbe.ActiveWindowGapTracker tracker =
        new AndroidMarkerProbe.ActiveWindowGapTracker();
    tracker.observe(1, 900_000_000L);
    tracker.observe(2, 1_600_000_000L);

    assertEquals(700_000_000L, tracker.snapshot().maxFrameGapNs());
  }

  @Test
  public void includesTheGapFromTheLastFrameToTheActiveWindowEnd() {
    AndroidMarkerProbe.ActiveWindowGapTracker tracker =
        new AndroidMarkerProbe.ActiveWindowGapTracker();
    tracker.observe(2, 1_000_000_000L);
    tracker.observe(2, 1_100_000_000L);
    tracker.observe(2, 2_200_000_000L);

    assertEquals(900_000_000L, tracker.snapshot().maxFrameGapNs());
  }

  @Test
  public void decodesMacCompatibleVersionSequenceAndCrc() {
    byte[] luma = markerLuma(0x1020_3040, 8);

    AndroidMarkerProbe.Marker marker = AndroidMarkerProbe.decodeLuma(
        luma, 96, 96, 96, 0, 0, 96);

    assertEquals(1, marker.version());
    assertEquals(0x1020_3040L, Integer.toUnsignedLong(marker.sequence()));
  }

  @Test
  public void decodesTheFirstValidCandidateRoi() {
    byte[] luma = markerLuma(8, 8);

    AndroidMarkerProbe.Marker marker = AndroidMarkerProbe.decodeLumaAtCandidateRois(
        luma, 96, 96, 96, new int[][] {{0, 0, 12}, {0, 0, 96}});

    assertEquals(8, marker.sequence());
  }

  @Test
  public void rejectsOneBitPayloadCorruption() {
    byte[] luma = markerLuma(42, 8);
    int cellX = 8;
    int cellY = 8;
    int sample = (cellY + 4) * 96 + cellX + 4;
    luma[sample] = (byte) ((luma[sample] & 0xff) == 0 ? 255 : 0);

    assertThrows(AndroidMarkerProbe.MarkerException.class,
        () -> AndroidMarkerProbe.decodeLuma(luma, 96, 96, 96, 0, 0, 96));
  }

  private static byte[] markerLuma(int sequence, int cellSize) {
    boolean[] cells = new boolean[12 * 12];
    for (int y = 0; y < 12; y++) {
      for (int x = 0; x < 12; x++) {
        if (x == 0 || y == 0 || x == 11 || y == 11) {
          cells[y * 12 + x] = finder(x, y);
        }
      }
    }
    byte[] payload = {
        1,
        (byte) (sequence >>> 24),
        (byte) (sequence >>> 16),
        (byte) (sequence >>> 8),
        (byte) sequence
    };
    int crc = crc16(payload);
    byte[] encoded = {payload[0], payload[1], payload[2], payload[3], payload[4],
        (byte) (crc >>> 8), (byte) crc};
    int bit = 0;
    for (byte value : encoded) {
      for (int shift = 7; shift >= 0; shift--) {
        int cellX = 1 + (bit % 10);
        int cellY = 1 + (bit / 10);
        cells[cellY * 12 + cellX] = ((value >>> shift) & 1) != 0;
        bit++;
      }
    }
    int size = 12 * cellSize;
    byte[] luma = new byte[size * size];
    for (int y = 0; y < size; y++) {
      for (int x = 0; x < size; x++) {
        luma[y * size + x] = (byte) (cells[(y / cellSize) * 12 + x / cellSize] ? 0 : 255);
      }
    }
    return luma;
  }

  private static boolean finder(int x, int y) {
    if (y == 0) {
      return x % 2 == 0;
    }
    if (x == 11) {
      return y % 2 == 0;
    }
    if (y == 11) {
      return x % 2 != 0;
    }
    return y % 2 != 0;
  }

  private static int crc16(byte[] bytes) {
    int crc = 0xffff;
    for (byte value : bytes) {
      crc ^= (value & 0xff) << 8;
      for (int bit = 0; bit < 8; bit++) {
        crc = (crc & 0x8000) != 0 ? (crc << 1) ^ 0x1021 : crc << 1;
        crc &= 0xffff;
      }
    }
    return crc;
  }
}
