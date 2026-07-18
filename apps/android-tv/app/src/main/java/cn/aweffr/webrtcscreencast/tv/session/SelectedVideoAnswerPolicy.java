package cn.aweffr.webrtcscreencast.tv.session;

import cn.aweffr.webrtcscreencast.tv.config.ReferenceRuntimeConfig.VideoCodec;
import java.util.LinkedHashSet;
import java.util.Locale;
import java.util.Set;
import java.util.regex.Matcher;
import java.util.regex.Pattern;

/** Ensures the generated answer preserves the configured reference codec. */
public final class SelectedVideoAnswerPolicy {
  private static final Pattern RTPMAP = Pattern.compile(
      "(?im)^a=rtpmap:\\d+\\s+([^/\\s]+)/\\d+", Pattern.CASE_INSENSITIVE);
  private static final Pattern H264_RTPMAP = Pattern.compile(
      "^a=rtpmap:(\\d+)\\s+H264/90000(?:\\s.*)?$", Pattern.CASE_INSENSITIVE);
  private static final Pattern PACKETIZATION_MODE_ONE = Pattern.compile(
      "(?:^|;)\\s*packetization-mode=1(?:;|$)", Pattern.CASE_INSENSITIVE);
  private static final Pattern PROFILE_LEVEL_ID = Pattern.compile(
      "profile-level-id=[0-9a-f]{6}", Pattern.CASE_INSENSITIVE);

  private SelectedVideoAnswerPolicy() {}

  public static String requireSelectedCodec(String sdp, VideoCodec selectedCodec) {
    if (sdp == null) {
      throw new IllegalArgumentException("answer_sdp_missing");
    }
    Set<String> available = new LinkedHashSet<>();
    Matcher matcher = RTPMAP.matcher(sdp);
    while (matcher.find()) {
      available.add(matcher.group(1).toLowerCase(Locale.ROOT));
    }
    if (!available.contains(selectedCodec.wireValue())) {
      String videoLine = "m=video missing";
      for (String line : sdp.split("\\r?\\n")) {
        if (line.startsWith("m=video ")) {
          videoLine = line;
          break;
        }
      }
      throw new IllegalArgumentException(
          "expected=" + selectedCodec.wireValue()
              + ",available=" + String.join(",", available)
              + "," + videoLine);
    }
    if (selectedCodec == VideoCodec.H264) {
      return normalizeH264For1080p(sdp);
    }
    return sdp;
  }

  private static String normalizeH264For1080p(String sdp) {
    String newline = sdp.contains("\r\n") ? "\r\n" : "\n";
    String[] lines = sdp.split("\\r?\\n", -1);
    Set<String> h264PayloadTypes = new LinkedHashSet<>();
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
      if (separator < 0 || !h264PayloadTypes.contains(line.substring(payloadStart, separator))) {
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
