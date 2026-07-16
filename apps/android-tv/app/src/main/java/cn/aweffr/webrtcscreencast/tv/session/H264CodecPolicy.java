package cn.aweffr.webrtcscreencast.tv.session;

import java.util.List;
import java.util.stream.Collectors;
import org.webrtc.RtpCapabilities;

/** Selects the single interoperable video codec contract for the reference receiver. */
public final class H264CodecPolicy {
  public static final class H264UnavailableException extends IllegalStateException {
    public H264UnavailableException() {
      super("h264_packetization_mode_1_unavailable");
    }
  }

  private H264CodecPolicy() {}

  public static List<RtpCapabilities.CodecCapability> requireReceiverCodecs(
      List<RtpCapabilities.CodecCapability> capabilities) {
    List<RtpCapabilities.CodecCapability> compatible = capabilities.stream()
        .filter(H264CodecPolicy::isCompatible)
        .collect(Collectors.toList());
    if (compatible.isEmpty()) {
      throw new H264UnavailableException();
    }
    return compatible;
  }

  private static boolean isCompatible(RtpCapabilities.CodecCapability codec) {
    if (codec == null || codec.parameters == null) {
      return false;
    }
    String name = codec.name == null ? "" : codec.name;
    if (!"H264".equalsIgnoreCase(name)) {
      return false;
    }
    return "1".equals(codec.parameters.get("packetization-mode"));
  }
}
