package cn.aweffr.webrtcscreencast.tv.observability;

import static org.junit.Assert.assertEquals;
import static org.junit.Assert.assertThrows;

import java.util.List;
import org.junit.Test;

public final class ClockCalibrationTest {
  @Test
  public void chooseUsesTheLowestRoundTripSample() {
    ClockCalibration calibration = ClockCalibration.choose(List.of(
        new ClockCalibration.Sample(1_000L, 1_500L, 10_200L),
        new ClockCalibration.Sample(2_000L, 2_100L, 11_050L)));

    assertEquals(100L, calibration.roundTripNs());
    assertEquals(9_000L, calibration.offsetNs());
    assertEquals(50L, calibration.uncertaintyNs());
    assertEquals(12_000L, calibration.toCommonTimeNs(3_000L));
  }

  @Test
  public void chooseRejectsEmptyOrNonIncreasingSamples() {
    assertThrows(IllegalArgumentException.class, () -> ClockCalibration.choose(List.of()));
    assertThrows(IllegalArgumentException.class, () -> ClockCalibration.choose(List.of(
        new ClockCalibration.Sample(100L, 100L, 1_000L))));
    assertThrows(IllegalArgumentException.class, () -> ClockCalibration.choose(List.of(
        new ClockCalibration.Sample(101L, 100L, 1_000L))));
  }

  @Test
  public void conversionRejectsLongOverflow() {
    ClockCalibration calibration = ClockCalibration.choose(List.of(
        new ClockCalibration.Sample(100L, 200L, 1_150L)));

    assertThrows(ArithmeticException.class,
        () -> calibration.toCommonTimeNs(Long.MAX_VALUE));
  }
}
