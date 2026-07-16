package cn.aweffr.webrtcscreencast.tv.session;

import java.util.HashSet;
import java.util.Locale;
import java.util.Set;
import java.util.regex.Matcher;
import java.util.regex.Pattern;

/** Makes the receiver's generated H.264 answer truthful for the 1080p reference contract. */
public final class H264AnswerPolicy {
  private static final Pattern H264_RTPMAP = Pattern.compile(
      "^a=rtpmap:(\\d+)\\s+H264/90000(?:\\s.*)?$", Pattern.CASE_INSENSITIVE);
  private static final Pattern PACKETIZATION_MODE_ONE = Pattern.compile(
      "(?:^|;)\\s*packetization-mode=1(?:;|$)", Pattern.CASE_INSENSITIVE);
  private static final Pattern PROFILE_LEVEL_ID = Pattern.compile(
      "profile-level-id=[0-9a-f]{6}", Pattern.CASE_INSENSITIVE);

  private H264AnswerPolicy() {}

  public static String normalizeFor1080p(String sdp) {
    if (sdp == null) {
      throw new IllegalArgumentException("answer_sdp_missing");
    }
    String newline = sdp.contains("\r\n") ? "\r\n" : "\n";
    String[] lines = sdp.split("\\r?\\n", -1);
    Set<String> h264PayloadTypes = new HashSet<>();
    for (String line : lines) {
      Matcher matcher = H264_RTPMAP.matcher(line);
      if (matcher.matches()) {
        h264PayloadTypes.add(matcher.group(1));
      }
    }

    boolean foundCompatible = false;
    for (int index = 0; index < lines.length; index++) {
      String line = lines[index];
      if (!line.toLowerCase(Locale.ROOT).startsWith("a=fmtp:")) {
        continue;
      }
      int payloadStart = "a=fmtp:".length();
      int separator = line.indexOf(' ', payloadStart);
      if (separator < 0 || !h264PayloadTypes.contains(
          line.substring(payloadStart, separator))) {
        continue;
      }
      String parameters = line.substring(separator + 1);
      if (!PACKETIZATION_MODE_ONE.matcher(parameters).find()) {
        continue;
      }
      foundCompatible = true;
      Matcher profile = PROFILE_LEVEL_ID.matcher(parameters);
      parameters = profile.find()
          ? profile.replaceFirst("profile-level-id=42e029")
          : parameters + ";profile-level-id=42e029";
      lines[index] = line.substring(0, separator + 1) + parameters;
    }
    if (!foundCompatible) {
      throw new IllegalArgumentException("h264_packetization_mode_1_answer_missing");
    }
    return String.join(newline, lines);
  }
}
