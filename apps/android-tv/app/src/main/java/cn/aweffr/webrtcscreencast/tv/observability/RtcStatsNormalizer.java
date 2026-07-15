package cn.aweffr.webrtcscreencast.tv.observability;

import cn.aweffr.webrtcscreencast.tv.config.ReferenceRuntimeConfig.IceProfile;
import java.util.Locale;
import java.util.Map;
import java.util.Objects;
import org.webrtc.RTCStats;

/** Converts WebRTC stats into a stable, candidate-address-free receiver evidence model. */
public final class RtcStatsNormalizer {
  public enum PathStatus {
    UNKNOWN,
    ACCEPTED,
    VIOLATION
  }

  public record InboundVideo(
      Long bytesReceived,
      Long packetsReceived,
      Long packetsLost,
      Long framesReceived,
      Long framesDecoded,
      Long framesDropped,
      Long keyFramesDecoded,
      Long qpSum,
      Double bitrateBps,
      Double jitterMs,
      Double totalDecodeTimeMs,
      Double totalInterFrameDelayMs,
      Double framesPerSecond,
      Integer frameWidth,
      Integer frameHeight,
      String decoderImplementation) {}

  public record SelectedPath(
      PathStatus status,
      String localCandidateType,
      String remoteCandidateType,
      String protocol) {}

  public record Sample(InboundVideo inbound, SelectedPath selectedPath) {}

  private final IceProfile profile;
  private Long previousTimestampUs;
  private Long previousBytesReceived;

  public RtcStatsNormalizer(IceProfile profile) {
    this.profile = Objects.requireNonNull(profile, "profile");
  }

  public Sample normalize(long timestampUs, Map<String, RTCStats> stats) {
    Objects.requireNonNull(stats, "stats");
    RTCStats inboundStat = stats.values().stream()
        .filter(stat -> "inbound-rtp".equals(stat.getType()))
        .filter(stat -> "video".equals(string(stat.getMembers(), "kind"))
            || "video".equals(string(stat.getMembers(), "mediaType")))
        .findFirst()
        .orElse(null);
    InboundVideo inbound = inboundStat == null
        ? null
        : normalizeInbound(timestampUs, inboundStat.getMembers());
    return new Sample(inbound, normalizePath(stats));
  }

  private InboundVideo normalizeInbound(long timestampUs, Map<String, Object> members) {
    Long bytesReceived = longValue(members, "bytesReceived");
    Double bitrateBps = null;
    if (bytesReceived != null
        && previousBytesReceived != null
        && previousTimestampUs != null
        && bytesReceived >= previousBytesReceived
        && timestampUs > previousTimestampUs) {
      bitrateBps = (bytesReceived - previousBytesReceived) * 8_000_000.0
          / (timestampUs - previousTimestampUs);
    }
    previousBytesReceived = bytesReceived;
    previousTimestampUs = timestampUs;
    Double jitter = doubleValue(members, "jitter");
    Double totalDecodeTime = doubleValue(members, "totalDecodeTime");
    Double totalInterFrameDelay = doubleValue(members, "totalInterFrameDelay");
    return new InboundVideo(
        bytesReceived,
        longValue(members, "packetsReceived"),
        longValue(members, "packetsLost"),
        longValue(members, "framesReceived"),
        longValue(members, "framesDecoded"),
        longValue(members, "framesDropped"),
        longValue(members, "keyFramesDecoded"),
        longValue(members, "qpSum"),
        bitrateBps,
        jitter == null ? null : jitter * 1_000.0,
        totalDecodeTime == null ? null : totalDecodeTime * 1_000.0,
        totalInterFrameDelay == null ? null : totalInterFrameDelay * 1_000.0,
        doubleValue(members, "framesPerSecond"),
        intValue(members, "frameWidth"),
        intValue(members, "frameHeight"),
        string(members, "decoderImplementation"));
  }

  private SelectedPath normalizePath(Map<String, RTCStats> stats) {
    String pairId = stats.values().stream()
        .filter(stat -> "transport".equals(stat.getType()))
        .map(stat -> string(stat.getMembers(), "selectedCandidatePairId"))
        .filter(Objects::nonNull)
        .findFirst()
        .orElse(null);
    RTCStats pair = pairId == null ? null : stats.get(pairId);
    if (pair == null || !"candidate-pair".equals(pair.getType())) {
      return new SelectedPath(PathStatus.UNKNOWN, null, null, null);
    }
    RTCStats local = stats.get(string(pair.getMembers(), "localCandidateId"));
    RTCStats remote = stats.get(string(pair.getMembers(), "remoteCandidateId"));
    if (local == null || remote == null) {
      return new SelectedPath(PathStatus.UNKNOWN, null, null, null);
    }
    String localType = lower(string(local.getMembers(), "candidateType"));
    String remoteType = lower(string(remote.getMembers(), "candidateType"));
    String protocol = lower(string(local.getMembers(), "protocol"));
    if (protocol == null) {
      protocol = lower(string(remote.getMembers(), "protocol"));
    }
    PathStatus status;
    if (localType == null || remoteType == null || protocol == null) {
      status = PathStatus.UNKNOWN;
    } else if (profile == IceProfile.PRODUCTION_RELAY) {
      status = "relay".equals(localType) && "udp".equals(protocol)
          ? PathStatus.ACCEPTED
          : PathStatus.VIOLATION;
    } else {
      status = !"relay".equals(localType)
              && !"relay".equals(remoteType)
              && "udp".equals(protocol)
          ? PathStatus.ACCEPTED
          : PathStatus.VIOLATION;
    }
    return new SelectedPath(status, localType, remoteType, protocol);
  }

  private static String string(Map<String, Object> values, String key) {
    Object value = values.get(key);
    return value instanceof String string ? string : null;
  }

  private static Long longValue(Map<String, Object> values, String key) {
    Object value = values.get(key);
    return value instanceof Number number ? number.longValue() : null;
  }

  private static Integer intValue(Map<String, Object> values, String key) {
    Object value = values.get(key);
    return value instanceof Number number ? number.intValue() : null;
  }

  private static Double doubleValue(Map<String, Object> values, String key) {
    Object value = values.get(key);
    return value instanceof Number number ? number.doubleValue() : null;
  }

  private static String lower(String value) {
    return value == null ? null : value.toLowerCase(Locale.ROOT);
  }
}
