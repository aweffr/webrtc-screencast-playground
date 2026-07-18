package cn.aweffr.webrtcscreencast.tv.session;

import static org.junit.Assert.assertEquals;
import static org.junit.Assert.assertThrows;

import java.util.List;
import java.util.Map;
import cn.aweffr.webrtcscreencast.tv.config.ReferenceRuntimeConfig.VideoCodec;
import org.junit.Test;
import org.webrtc.MediaStreamTrack;
import org.webrtc.RtpCapabilities;

public final class SelectedVideoCodecPolicyTest {
  @Test
  public void keepsOnlyConfiguredCodecForHeadToHeadExperiment() {
    RtpCapabilities.CodecCapability vp8 = codec("VP8", Map.of());
    RtpCapabilities.CodecCapability h264ModeZero = codec(
        "H264", Map.of("packetization-mode", "0"));
    RtpCapabilities.CodecCapability h264ModeOne = codec(
        "H264", Map.of("packetization-mode", "1", "profile-level-id", "42e01f"));
    RtpCapabilities.CodecCapability h265 = codec("H265", Map.of());

    List<RtpCapabilities.CodecCapability> h264Only = SelectedVideoCodecPolicy.requireReceiverCodecs(
        List.of(vp8, h264ModeZero, h264ModeOne, h265), VideoCodec.H264);
    List<RtpCapabilities.CodecCapability> h265Only = SelectedVideoCodecPolicy.requireReceiverCodecs(
        List.of(vp8, h264ModeZero, h264ModeOne, h265), VideoCodec.H265);

    assertEquals(List.of(h264ModeOne), h264Only);
    assertEquals(List.of(h265), h265Only);
  }

  @Test
  public void failsWhenH265IsUnavailable() {
    assertThrows(SelectedVideoCodecPolicy.CodecUnavailableException.class,
        () -> SelectedVideoCodecPolicy.requireReceiverCodecs(
            List.of(codec("VP9", Map.of())), VideoCodec.H265));
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
