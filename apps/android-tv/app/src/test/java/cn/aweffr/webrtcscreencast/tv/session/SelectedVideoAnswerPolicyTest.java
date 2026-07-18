package cn.aweffr.webrtcscreencast.tv.session;

import static org.junit.Assert.assertEquals;
import static org.junit.Assert.assertThrows;
import static org.junit.Assert.assertTrue;

import org.junit.Test;
import cn.aweffr.webrtcscreencast.tv.config.ReferenceRuntimeConfig.VideoCodec;

public final class SelectedVideoAnswerPolicyTest {
  @Test
  public void acceptsH265AnswerWithoutRewritingIt() {
    String answer = String.join("\r\n",
        "v=0",
        "a=rtpmap:96 H265/90000",
        "a=rtpmap:100 VP8/90000",
        "");

    String normalized = SelectedVideoAnswerPolicy.requireSelectedCodec(answer, VideoCodec.H265);

    assertEquals(String.join("\r\n",
        "v=0",
        "a=rtpmap:96 H265/90000",
        "a=rtpmap:100 VP8/90000",
        ""), normalized);
  }

  @Test
  public void rejectsAnswerWithoutH265() {
    assertThrows(IllegalArgumentException.class,
        () -> SelectedVideoAnswerPolicy.requireSelectedCodec(
            "v=0\r\na=rtpmap:100 VP8/90000\r\n", VideoCodec.H265));
  }

  @Test
  public void acceptsH264ForReferenceBaseline() {
    String answer = String.join("\r\n",
        "v=0",
        "a=rtpmap:96 H264/90000",
        "a=fmtp:96 level-asymmetry-allowed=1;packetization-mode=1;profile-level-id=42e01f",
        "");

    String normalized = SelectedVideoAnswerPolicy.requireSelectedCodec(answer, VideoCodec.H264);

    assertTrue(normalized.contains("profile-level-id=42e029"));
  }

  @Test
  public void mismatchReportsOnlyAvailableCodecNames() {
    IllegalArgumentException error = assertThrows(IllegalArgumentException.class, () ->
        SelectedVideoAnswerPolicy.requireSelectedCodec(
            "v=0\r\na=rtpmap:96 VP8/90000\r\na=rtpmap:97 H265/90000\r\n",
            VideoCodec.H264));

    assertTrue(error.getMessage().contains("expected=h264"));
    assertTrue(error.getMessage().contains("available=vp8,h265"));
  }
}
