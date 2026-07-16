package cn.aweffr.webrtcscreencast.tv.config;

import static org.junit.Assert.assertEquals;
import static org.junit.Assert.assertThrows;

import org.junit.Test;

public final class ReferenceRuntimeConfigTest {
  private static final String TUNING_JSON = "{\"schema_version\":2}";

  @Test
  public void directBaselineDoesNotRequireTurnCredentials() {
    ReferenceRuntimeConfig config = ReferenceRuntimeConfig.create(
        "ws://10.0.2.2:8080/ws", "direct-baseline", "", "", "", TUNING_JSON);

    config.validate();
    assertEquals(ReferenceRuntimeConfig.IceProfile.DIRECT_BASELINE, config.iceProfile());
  }

  @Test
  public void productionRelayRequiresRealTurnUdpCredentials() {
    ReferenceRuntimeConfig missing = ReferenceRuntimeConfig.create(
        "ws://10.0.2.2:8080/ws",
        "production-relay",
        "turn:turn.example.invalid:3478?transport=udp",
        "REPLACE_ME",
        "REPLACE_ME",
        TUNING_JSON);
    ReferenceRuntimeConfig.ConfigException error = assertThrows(
        ReferenceRuntimeConfig.ConfigException.class, missing::validate);
    assertEquals("missing_turn_credentials", error.code());

    ReferenceRuntimeConfig tcp = ReferenceRuntimeConfig.create(
        "ws://10.0.2.2:8080/ws",
        "production-relay",
        "turn:turn.example.invalid:3478?transport=tcp",
        "user",
        "password",
        TUNING_JSON);
    error = assertThrows(ReferenceRuntimeConfig.ConfigException.class, tcp::validate);
    assertEquals("invalid_turn_udp_url", error.code());

    ReferenceRuntimeConfig valid = ReferenceRuntimeConfig.create(
        "ws://10.0.2.2:8080/ws",
        "production-relay",
        "turn:turn.example.invalid:3478?transport=udp",
        "user",
        "password",
        TUNING_JSON);
    valid.validate();
  }

  @Test
  public void redactedHashDoesNotContainOrDependOnCredentials() {
    ReferenceRuntimeConfig first = ReferenceRuntimeConfig.create(
        "ws://10.0.2.2:8080/ws",
        "production-relay",
        "turn:turn.example.invalid:3478?transport=udp",
        "first-user",
        "first-password",
        TUNING_JSON);
    ReferenceRuntimeConfig second = ReferenceRuntimeConfig.create(
        "ws://10.0.2.2:8080/ws",
        "production-relay",
        "turn:turn.example.invalid:3478?transport=udp",
        "second-user",
        "second-password",
        TUNING_JSON);

    assertEquals(first.redactedHash(), second.redactedHash());
  }

  @Test
  public void signalingRequiresAWebSocketUrl() {
    ReferenceRuntimeConfig config = ReferenceRuntimeConfig.create(
        "https://10.0.2.2:8080/ws", "direct-baseline", "", "", "", TUNING_JSON);

    ReferenceRuntimeConfig.ConfigException error = assertThrows(
        ReferenceRuntimeConfig.ConfigException.class, config::validate);
    assertEquals("invalid_signaling_url", error.code());
  }
}
