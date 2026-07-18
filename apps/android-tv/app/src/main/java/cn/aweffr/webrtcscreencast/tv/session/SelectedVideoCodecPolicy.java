package cn.aweffr.webrtcscreencast.tv.session;

import cn.aweffr.webrtcscreencast.tv.config.ReferenceRuntimeConfig.VideoCodec;
import java.util.List;
import java.util.stream.Collectors;
import org.webrtc.RtpCapabilities;

/** Selects the configured reference codec for a comparable receiver path. */
public final class SelectedVideoCodecPolicy {
  public static final class CodecUnavailableException extends IllegalStateException {
    public CodecUnavailableException(VideoCodec codec) {
      super(codec.wireValue() + "_unavailable");
    }
  }

  private SelectedVideoCodecPolicy() {}

  public static List<RtpCapabilities.CodecCapability> requireReceiverCodecs(
      List<RtpCapabilities.CodecCapability> capabilities,
      VideoCodec selectedCodec) {
    List<RtpCapabilities.CodecCapability> compatible = capabilities.stream()
        .filter(codec -> isCompatible(codec, selectedCodec))
        .collect(Collectors.toList());
    if (compatible.isEmpty()) {
      throw new CodecUnavailableException(selectedCodec);
    }
    return compatible;
  }

  private static boolean isCompatible(
      RtpCapabilities.CodecCapability codec,
      VideoCodec selectedCodec) {
    if (codec == null) {
      return false;
    }
    String name = codec.name == null ? "" : codec.name;
    if (!selectedCodec.sdpName().equalsIgnoreCase(name)) {
      return false;
    }
    return selectedCodec != VideoCodec.H264
        || (codec.parameters != null
            && "1".equals(codec.parameters.get("packetization-mode")));
  }
}
