package cn.aweffr.webrtcscreencast.tv.session;

import static org.junit.Assert.assertEquals;
import static org.junit.Assert.assertThrows;

import java.util.List;
import java.util.Map;
import org.junit.Test;
import org.webrtc.MediaStreamTrack;
import org.webrtc.RtpCapabilities;

public final class SelectedVideoCodecPolicyTest {
  @Test
  public void keepsOnlyH265() {
    RtpCapabilities.CodecCapability vp8 = codec("VP8", Map.of());
    RtpCapabilities.CodecCapability h264 = codec("H264", Map.of("packetization-mode", "1"));
    RtpCapabilities.CodecCapability h265 = codec("H265", Map.of());

    List<RtpCapabilities.CodecCapability> filtered = SelectedVideoCodecPolicy.requireReceiverCodecs(
        List.of(vp8, h264, h265));

    assertEquals(List.of(h265), filtered);
  }

  @Test
  public void failsWhenH265IsUnavailable() {
    assertThrows(SelectedVideoCodecPolicy.CodecUnavailableException.class,
        () -> SelectedVideoCodecPolicy.requireReceiverCodecs(List.of(codec("VP9", Map.of()))));
  }

  private static RtpCapabilities.CodecCapability codec(
      String name, Map<String, String> parameters) {
    RtpCapabilities.CodecCapability codec = new RtpCapabilities.CodecCapability();
    codec.name = name;
    codec.mimeType = "video/" + name;
    codec.kind = MediaStreamTrack.MediaType.MEDIA_TYPE_VIDEO;
    codec.parameters = parameters;
    return codec;
  }
}
