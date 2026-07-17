package cn.aweffr.webrtcscreencast.tv.session;

import java.util.List;
import java.util.stream.Collectors;
import org.webrtc.RtpCapabilities;

/** Selects the HEVC video codec required by the reference cast session. */
public final class SelectedVideoCodecPolicy {
  public static final class CodecUnavailableException extends IllegalStateException {
    public CodecUnavailableException() {
      super("h265_unavailable");
    }
  }

  private SelectedVideoCodecPolicy() {}

  public static List<RtpCapabilities.CodecCapability> requireReceiverCodecs(
      List<RtpCapabilities.CodecCapability> capabilities) {
    List<RtpCapabilities.CodecCapability> compatible = capabilities.stream()
        .filter(SelectedVideoCodecPolicy::isCompatible)
        .collect(Collectors.toList());
    if (compatible.isEmpty()) {
      throw new CodecUnavailableException();
    }
    return compatible;
  }

  private static boolean isCompatible(RtpCapabilities.CodecCapability codec) {
    if (codec == null) {
      return false;
    }
    String name = codec.name == null ? "" : codec.name;
    return "H265".equalsIgnoreCase(name);
  }
}
