package cn.aweffr.webrtcscreencast.tv.session;

import static org.junit.Assert.assertEquals;
import static org.junit.Assert.assertThrows;

import org.junit.Test;

public final class H264AnswerPolicyTest {
  @Test
  public void normalizesSelectedPacketizationModeOneToLevel41() {
    String answer = String.join("\r\n",
        "v=0",
        "a=rtpmap:96 H264/90000",
        "a=fmtp:96 level-asymmetry-allowed=1;packetization-mode=1;profile-level-id=42e01f",
        "a=rtpmap:98 H264/90000",
        "a=fmtp:98 packetization-mode=0;profile-level-id=42e01f",
        "a=rtpmap:100 VP8/90000",
        "");

    String normalized = H264AnswerPolicy.normalizeFor1080p(answer);

    assertEquals(String.join("\r\n",
        "v=0",
        "a=rtpmap:96 H264/90000",
        "a=fmtp:96 level-asymmetry-allowed=1;packetization-mode=1;profile-level-id=42e029",
        "a=rtpmap:98 H264/90000",
        "a=fmtp:98 packetization-mode=0;profile-level-id=42e01f",
        "a=rtpmap:100 VP8/90000",
        ""), normalized);
  }

  @Test
  public void rejectsAnswerWithoutCompatibleH264Fmtp() {
    assertThrows(IllegalArgumentException.class,
        () -> H264AnswerPolicy.normalizeFor1080p(
            "v=0\r\na=rtpmap:100 VP8/90000\r\n"));
  }
}
