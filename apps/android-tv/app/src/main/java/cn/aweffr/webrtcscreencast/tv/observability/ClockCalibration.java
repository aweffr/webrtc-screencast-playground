package cn.aweffr.webrtcscreencast.tv.observability;

import java.util.List;
import java.util.Objects;

/** Maps one process-local monotonic clock into the signaling server's common time domain. */
public final class ClockCalibration {
  public static final class Sample {
    private final long startedMonotonicNs;
    private final long finishedMonotonicNs;
    private final long serverUnixNs;

    public Sample(long startedMonotonicNs, long finishedMonotonicNs, long serverUnixNs) {
      this.startedMonotonicNs = startedMonotonicNs;
      this.finishedMonotonicNs = finishedMonotonicNs;
      this.serverUnixNs = serverUnixNs;
    }
  }

  private final long offsetNs;
  private final long roundTripNs;
  private final long uncertaintyNs;

  private ClockCalibration(long offsetNs, long roundTripNs) {
    this.offsetNs = offsetNs;
    this.roundTripNs = roundTripNs;
    this.uncertaintyNs = roundTripNs / 2;
  }

  public static ClockCalibration choose(List<Sample> samples) {
    Objects.requireNonNull(samples, "samples");
    if (samples.isEmpty()) {
      throw new IllegalArgumentException("at least one clock sample is required");
    }

    ClockCalibration selected = null;
    for (Sample sample : samples) {
      Objects.requireNonNull(sample, "clock sample");
      long roundTripNs = Math.subtractExact(
          sample.finishedMonotonicNs, sample.startedMonotonicNs);
      if (roundTripNs <= 0) {
        throw new IllegalArgumentException("clock sample must have a positive round trip");
      }
      long midpointNs = Math.addExact(
          sample.startedMonotonicNs, roundTripNs / 2);
      long offsetNs = Math.subtractExact(sample.serverUnixNs, midpointNs);
      if (selected == null || roundTripNs < selected.roundTripNs) {
        selected = new ClockCalibration(offsetNs, roundTripNs);
      }
    }
    return selected;
  }

  public long offsetNs() {
    return offsetNs;
  }

  public long roundTripNs() {
    return roundTripNs;
  }

  public long uncertaintyNs() {
    return uncertaintyNs;
  }

  public long toCommonTimeNs(long localMonotonicNs) {
    return Math.addExact(localMonotonicNs, offsetNs);
  }
}
