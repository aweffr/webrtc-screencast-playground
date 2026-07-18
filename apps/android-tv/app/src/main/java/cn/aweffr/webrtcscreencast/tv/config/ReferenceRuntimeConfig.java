package cn.aweffr.webrtcscreencast.tv.config;

import android.content.res.Resources;
import cn.aweffr.webrtcscreencast.tv.R;
import java.net.URI;
import java.net.URISyntaxException;
import java.nio.charset.StandardCharsets;
import java.security.MessageDigest;
import java.security.NoSuchAlgorithmException;
import java.util.Locale;
import java.util.Objects;

/** Single XML-backed runtime configuration entry point for the reference receiver. */
public final class ReferenceRuntimeConfig {
  public enum IceProfile {
    DIRECT_BASELINE("direct-baseline"),
    PRODUCTION_RELAY("production-relay");

    private final String wireValue;

    IceProfile(String wireValue) {
      this.wireValue = wireValue;
    }

    public String wireValue() {
      return wireValue;
    }

    private static IceProfile parse(String value) {
      for (IceProfile profile : values()) {
        if (profile.wireValue.equals(value)) {
          return profile;
        }
      }
      throw new ConfigException("unsupported_ice_profile", "Unsupported ICE profile");
    }
  }

  public enum VideoCodec {
    H264("h264", "H264"),
    H265("h265", "H265");

    private final String wireValue;
    private final String sdpName;

    VideoCodec(String wireValue, String sdpName) {
      this.wireValue = wireValue;
      this.sdpName = sdpName;
    }

    public String wireValue() {
      return wireValue;
    }

    public String sdpName() {
      return sdpName;
    }

    private static VideoCodec parse(String value) {
      for (VideoCodec codec : values()) {
        if (codec.wireValue.equals(value)) {
          return codec;
        }
      }
      throw new ConfigException("unsupported_video_codec", "Unsupported video codec");
    }
  }

  public static final class ConfigException extends IllegalArgumentException {
    private final String code;

    public ConfigException(String code, String message) {
      super(message);
      this.code = code;
    }

    public String code() {
      return code;
    }
  }

  private final String signalingUrl;
  private final IceProfile iceProfile;
  private final String turnUrl;
  private final String turnUsername;
  private final String turnPassword;
  private final String castTuningJson;
  private final VideoCodec videoCodec;

  private ReferenceRuntimeConfig(
      String signalingUrl,
      IceProfile iceProfile,
      String turnUrl,
      String turnUsername,
      String turnPassword,
      String castTuningJson,
      VideoCodec videoCodec) {
    this.signalingUrl = signalingUrl.trim();
    this.iceProfile = iceProfile;
    this.turnUrl = turnUrl.trim();
    this.turnUsername = turnUsername.trim();
    this.turnPassword = turnPassword.trim();
    this.castTuningJson = castTuningJson.trim();
    this.videoCodec = videoCodec;
  }

  public static ReferenceRuntimeConfig load(Resources resources) {
    Objects.requireNonNull(resources, "resources");
    return create(
        resources.getString(R.string.reference_signaling_url),
        resources.getString(R.string.reference_ice_profile),
        resources.getString(R.string.reference_turn_url),
        resources.getString(R.string.reference_turn_username),
        resources.getString(R.string.reference_turn_password),
        resources.getString(R.string.reference_cast_tuning_json),
        resources.getString(R.string.reference_video_codec));
  }

  public static ReferenceRuntimeConfig create(
      String signalingUrl,
      String iceProfile,
      String turnUrl,
      String turnUsername,
      String turnPassword,
      String castTuningJson,
      String videoCodec) {
    return new ReferenceRuntimeConfig(
        Objects.requireNonNull(signalingUrl, "signalingUrl"),
        IceProfile.parse(Objects.requireNonNull(iceProfile, "iceProfile").trim()),
        Objects.requireNonNull(turnUrl, "turnUrl"),
        Objects.requireNonNull(turnUsername, "turnUsername"),
        Objects.requireNonNull(turnPassword, "turnPassword"),
        Objects.requireNonNull(castTuningJson, "castTuningJson"),
        VideoCodec.parse(Objects.requireNonNull(videoCodec, "videoCodec").trim()));
  }

  public void validate() {
    URI signaling = parseUri(signalingUrl, "invalid_signaling_url");
    String signalingScheme = lower(signaling.getScheme());
    if (!("ws".equals(signalingScheme) || "wss".equals(signalingScheme))
        || signaling.getHost() == null) {
      throw new ConfigException("invalid_signaling_url", "Signaling must use ws or wss");
    }
    if (castTuningJson.isEmpty() || isPlaceholder(castTuningJson)) {
      throw new ConfigException("missing_cast_tuning", "CastTuning JSON is required");
    }
    if (iceProfile != IceProfile.PRODUCTION_RELAY) {
      return;
    }
    if (isPlaceholder(turnUsername) || isPlaceholder(turnPassword)) {
      throw new ConfigException(
          "missing_turn_credentials", "TURN username and password must be configured locally");
    }
    if (!isTurnUdpUrl(turnUrl)) {
      throw new ConfigException(
          "invalid_turn_udp_url", "Production relay requires a turn URL with transport=udp");
    }
  }

  public String signalingUrl() {
    return signalingUrl;
  }

  public IceProfile iceProfile() {
    return iceProfile;
  }

  public String turnUrl() {
    return turnUrl;
  }

  public String turnUsername() {
    return turnUsername;
  }

  public String turnPassword() {
    return turnPassword;
  }

  public String castTuningJson() {
    return castTuningJson;
  }

  public VideoCodec videoCodec() {
    return videoCodec;
  }

  public String redactedHash() {
    String canonical = String.join("\n",
        signalingUrl,
        iceProfile.wireValue,
        turnUrl,
        Boolean.toString(!isPlaceholder(turnUsername)),
        Boolean.toString(!isPlaceholder(turnPassword)),
        castTuningJson,
        videoCodec.wireValue);
    try {
      byte[] digest = MessageDigest.getInstance("SHA-256")
          .digest(canonical.getBytes(StandardCharsets.UTF_8));
      return toLowerHex(digest);
    } catch (NoSuchAlgorithmException error) {
      throw new IllegalStateException("SHA-256 is unavailable", error);
    }
  }

  private static URI parseUri(String value, String code) {
    try {
      return new URI(value);
    } catch (URISyntaxException error) {
      throw new ConfigException(code, "Runtime URL is invalid");
    }
  }

  private static boolean hasUdpTransport(String rawQuery) {
    if (rawQuery == null) {
      return false;
    }
    for (String item : rawQuery.split("&")) {
      if ("transport=udp".equals(lower(item))) {
        return true;
      }
    }
    return false;
  }

  private static boolean isTurnUdpUrl(String value) {
    String normalized = lower(value.trim());
    if (!normalized.startsWith("turn:")) {
      return false;
    }
    int queryStart = normalized.indexOf('?');
    if (queryStart <= "turn:".length() || queryStart == normalized.length() - 1) {
      return false;
    }
    String endpoint = normalized.substring("turn:".length(), queryStart);
    return !endpoint.isBlank()
        && endpoint.chars().noneMatch(Character::isWhitespace)
        && hasUdpTransport(normalized.substring(queryStart + 1));
  }

  private static boolean isPlaceholder(String value) {
    return value.isEmpty() || "REPLACE_ME".equals(value);
  }

  private static String toLowerHex(byte[] bytes) {
    char[] alphabet = "0123456789abcdef".toCharArray();
    char[] result = new char[bytes.length * 2];
    for (int index = 0; index < bytes.length; index++) {
      int value = bytes[index] & 0xff;
      result[index * 2] = alphabet[value >>> 4];
      result[index * 2 + 1] = alphabet[value & 0x0f];
    }
    return new String(result);
  }

  private static String lower(String value) {
    return value == null ? "" : value.toLowerCase(Locale.ROOT);
  }
}
