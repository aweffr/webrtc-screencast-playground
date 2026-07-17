package cn.aweffr.webrtcscreencast.tv.session;

import static org.junit.Assert.assertEquals;
import static org.junit.Assert.assertThrows;

import org.junit.Test;

public final class SelectedVideoAnswerPolicyTest {
  @Test
  public void acceptsH265AnswerWithoutRewritingIt() {
    String answer = String.join("\r\n",
        "v=0",
        "a=rtpmap:96 H265/90000",
        "a=rtpmap:100 VP8/90000",
        "");

    String normalized = SelectedVideoAnswerPolicy.requireSelectedCodec(answer);

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
            "v=0\r\na=rtpmap:100 VP8/90000\r\n"));
  }
}
