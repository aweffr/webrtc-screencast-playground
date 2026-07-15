package cn.aweffr.webrtcscreencast.tv.observability;

import static org.junit.Assert.assertEquals;
import static org.junit.Assert.assertFalse;
import static org.junit.Assert.assertNull;

import cn.aweffr.webrtcscreencast.tv.config.ReferenceRuntimeConfig.IceProfile;
import java.util.HashMap;
import java.util.LinkedHashMap;
import java.util.Map;
import org.junit.Test;
import org.webrtc.RTCStats;

public final class RtcStatsNormalizerTest {
  @Test
  public void normalizesInboundVideoAndDerivesBitrateWithoutInventingMissingValues() {
    RtcStatsNormalizer normalizer = new RtcStatsNormalizer(IceProfile.DIRECT_BASELINE);
    Map<String, RTCStats> first = directFixture(1_000L);
    Map<String, RTCStats> second = directFixture(2_000L);

    RtcStatsNormalizer.Sample initial = normalizer.normalize(1_000_000L, first);
    RtcStatsNormalizer.Sample sample = normalizer.normalize(2_000_000L, second);

    assertNull(initial.inbound().bitrateBps());
    assertEquals(8_000.0, sample.inbound().bitrateBps(), 0.001);
    assertEquals(Long.valueOf(2_000L), sample.inbound().bytesReceived());
    assertEquals(Long.valueOf(58L), sample.inbound().framesDecoded());
    assertEquals(Integer.valueOf(1_920), sample.inbound().frameWidth());
    assertEquals(Integer.valueOf(1_080), sample.inbound().frameHeight());
    assertEquals("c2.android.avc.decoder", sample.inbound().decoderImplementation());
    assertEquals("video/H264", sample.inbound().codecMimeType());
    assertNull(sample.inbound().qpSum());
  }

  @Test
  public void verifiesDirectAndRelayUdpPathsExplicitly() {
    RtcStatsNormalizer direct = new RtcStatsNormalizer(IceProfile.DIRECT_BASELINE);
    RtcStatsNormalizer.Sample directSample = direct.normalize(1_000_000L, directFixture(1_000L));
    assertEquals(RtcStatsNormalizer.PathStatus.ACCEPTED, directSample.selectedPath().status());
    assertEquals("host", directSample.selectedPath().localCandidateType());
    assertEquals("udp", directSample.selectedPath().protocol());

    RtcStatsNormalizer relay = new RtcStatsNormalizer(IceProfile.PRODUCTION_RELAY);
    RtcStatsNormalizer.Sample relaySample = relay.normalize(1_000_000L, relayFixture("udp"));
    assertEquals(RtcStatsNormalizer.PathStatus.ACCEPTED, relaySample.selectedPath().status());

    RtcStatsNormalizer.Sample tcp = new RtcStatsNormalizer(IceProfile.PRODUCTION_RELAY)
        .normalize(1_000_000L, relayFixture("tcp"));
    assertEquals(RtcStatsNormalizer.PathStatus.VIOLATION, tcp.selectedPath().status());

    Map<String, RTCStats> oneSidedRelay = relayFixture("udp");
    oneSidedRelay.put("remote", stat("remote-candidate", "remote", Map.of(
        "candidateType", "srflx", "protocol", "udp")));
    assertEquals(
        RtcStatsNormalizer.PathStatus.VIOLATION,
        new RtcStatsNormalizer(IceProfile.PRODUCTION_RELAY)
            .normalize(1_000_000L, oneSidedRelay).selectedPath().status());
  }

  @Test
  public void outputDiscardsCandidateAddressesAndRawCandidateStrings() {
    RtcStatsNormalizer.Sample sample = new RtcStatsNormalizer(IceProfile.PRODUCTION_RELAY)
        .normalize(1_000_000L, relayFixture("udp"));
    String diagnostic = sample.toString();

    assertFalse(diagnostic.contains("203.0.113.9"));
    assertFalse(diagnostic.contains("candidate:secret"));
  }

  @Test
  public void missingCodecIdProducesNullCapabilityInsteadOfCrashing() {
    Map<String, RTCStats> mutable = directFixture(1_000L);
    Map<String, Object> inbound = new HashMap<>(mutable.get("inbound").getMembers());
    inbound.remove("codecId");
    mutable.put("inbound", stat("inbound-rtp", "inbound", Map.copyOf(inbound)));

    RtcStatsNormalizer.Sample sample = new RtcStatsNormalizer(IceProfile.DIRECT_BASELINE)
        .normalize(1_000_000L, Map.copyOf(mutable));

    assertNull(sample.inbound().codecMimeType());
  }

  private static Map<String, RTCStats> directFixture(long bytesReceived) {
    Map<String, RTCStats> stats = commonFixture(bytesReceived);
    stats.put("local", stat("local-candidate", "local", Map.of(
        "candidateType", "host",
        "protocol", "udp",
        "address", "192.168.1.2",
        "candidate", "candidate:secret")));
    stats.put("remote", stat("remote-candidate", "remote", Map.of(
        "candidateType", "host", "protocol", "udp")));
    return stats;
  }

  private static Map<String, RTCStats> relayFixture(String protocol) {
    Map<String, RTCStats> stats = commonFixture(1_000L);
    stats.put("local", stat("local-candidate", "local", Map.of(
        "candidateType", "relay",
        "protocol", protocol,
        "address", "203.0.113.9",
        "candidate", "candidate:secret")));
    stats.put("remote", stat("remote-candidate", "remote", Map.of(
        "candidateType", "relay", "protocol", protocol)));
    return stats;
  }

  private static Map<String, RTCStats> commonFixture(long bytesReceived) {
    Map<String, RTCStats> stats = new LinkedHashMap<>();
    stats.put("inbound", stat("inbound-rtp", "inbound", Map.ofEntries(
        Map.entry("kind", "video"),
        Map.entry("codecId", "codec"),
        Map.entry("bytesReceived", bytesReceived),
        Map.entry("framesReceived", 60L),
        Map.entry("framesDecoded", 58L),
        Map.entry("framesDropped", 2L),
        Map.entry("packetsLost", 1L),
        Map.entry("jitter", 0.004),
        Map.entry("frameWidth", 1_920),
        Map.entry("frameHeight", 1_080),
        Map.entry("framesPerSecond", 30.0),
        Map.entry("decoderImplementation", "c2.android.avc.decoder"))));
    stats.put("codec", stat("codec", "codec", Map.of("mimeType", "video/H264")));
    stats.put("transport", stat("transport", "transport", Map.of(
        "selectedCandidatePairId", "pair")));
    stats.put("pair", stat("candidate-pair", "pair", Map.of(
        "state", "succeeded",
        "localCandidateId", "local",
        "remoteCandidateId", "remote")));
    return stats;
  }

  private static RTCStats stat(String type, String id, Map<String, Object> members) {
    return new RTCStats(0L, type, id, members);
  }
}
