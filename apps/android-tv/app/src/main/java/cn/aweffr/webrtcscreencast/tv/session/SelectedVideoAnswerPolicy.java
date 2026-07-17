package cn.aweffr.webrtcscreencast.tv.session;

import java.util.regex.Pattern;

/** Ensures the generated answer preserves the selected HEVC codec. */
public final class SelectedVideoAnswerPolicy {
  private static final Pattern H265_RTPMAP = Pattern.compile(
      "(?m)^a=rtpmap:\\d+\\s+H265/90000(?:\\s.*)?$", Pattern.CASE_INSENSITIVE);

  private SelectedVideoAnswerPolicy() {}

  public static String requireSelectedCodec(String sdp) {
    if (sdp == null) {
      throw new IllegalArgumentException("answer_sdp_missing");
    }
    if (!H265_RTPMAP.matcher(sdp).find()) {
      throw new IllegalArgumentException("h265_answer_missing");
    }
    return sdp;
  }
}
