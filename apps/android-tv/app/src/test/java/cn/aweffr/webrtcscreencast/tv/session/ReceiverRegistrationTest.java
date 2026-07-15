package cn.aweffr.webrtcscreencast.tv.session;

import static org.junit.Assert.assertEquals;
import static org.junit.Assert.assertThrows;

import cn.aweffr.webrtcscreencast.tv.signaling.SignalingCodec;
import cn.aweffr.webrtcscreencast.tv.signaling.SignalingMessage;
import java.time.Instant;
import org.junit.Test;

public final class ReceiverRegistrationTest {
  @Test
  public void parsesTheGoServerProtocolFixture() {
    SignalingMessage message = SignalingCodec.decode("""
        {"version":1,"message_id":"server-1","type":"receiver.registered",
        "payload":{"session_id":"session-1","pairing_code":"01ABCD23",
        "expires_at":"2026-07-14T01:02:03Z"}}
        """);

    ReceiverController.Registration registration =
        ReceiverController.parseRegistration(message);

    assertEquals("session-1", registration.sessionId());
    assertEquals("01ABCD23", registration.pairingCode());
    assertEquals(Instant.parse("2026-07-14T01:02:03Z"), registration.expiresAt());
  }

  @Test
  public void parsesGoServerTimestampWithLocalOffsetAndMicroseconds() {
    SignalingMessage message = SignalingCodec.decode("""
        {"version":1,"message_id":"server-1","type":"receiver.registered",
        "payload":{"session_id":"session-1","pairing_code":"01ABCD23",
        "expires_at":"2026-07-16T01:45:18.759902+08:00"}}
        """);

    ReceiverController.Registration registration =
        ReceiverController.parseRegistration(message);

    assertEquals(Instant.parse("2026-07-15T17:45:18.759902Z"), registration.expiresAt());
  }

  @Test
  public void invalidExpiryProducesASafeStableErrorCode() {
    SignalingMessage message = SignalingCodec.decode("""
        {"version":1,"message_id":"server-1","type":"receiver.registered",
        "payload":{"session_id":"session-1","pairing_code":"01ABCD23",
        "expires_at":"not-an-instant"}}
        """);

    ReceiverController.ProtocolHandlingException error = assertThrows(
        ReceiverController.ProtocolHandlingException.class,
        () -> ReceiverController.parseRegistration(message));

    assertEquals("receiver_registration_expiry_invalid", error.code());
  }
}
