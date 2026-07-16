package cn.aweffr.webrtcscreencast.tv.session;

import static org.junit.Assert.assertEquals;
import static org.junit.Assert.assertThrows;

import java.util.List;
import java.util.Map;
import org.junit.Test;
import org.webrtc.MediaStreamTrack;
import org.webrtc.RtpCapabilities;

public final class H264CodecPolicyTest {
  @Test
  public void keepsOnlyH264PacketizationModeOne() {
    RtpCapabilities.CodecCapability vp8 = codec("VP8", Map.of());
    RtpCapabilities.CodecCapability h264ModeZero = codec(
        "H264", Map.of("packetization-mode", "0"));
    RtpCapabilities.CodecCapability h264ModeOne = codec(
        "H264", Map.of("packetization-mode", "1", "profile-level-id", "42e01f"));

    List<RtpCapabilities.CodecCapability> filtered = H264CodecPolicy.requireReceiverCodecs(
        List.of(vp8, h264ModeZero, h264ModeOne));

    assertEquals(List.of(h264ModeOne), filtered);
  }

  @Test
  public void failsWhenCompatibleH264IsUnavailable() {
    assertThrows(H264CodecPolicy.H264UnavailableException.class,
        () -> H264CodecPolicy.requireReceiverCodecs(List.of(codec("VP9", Map.of()))));
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
