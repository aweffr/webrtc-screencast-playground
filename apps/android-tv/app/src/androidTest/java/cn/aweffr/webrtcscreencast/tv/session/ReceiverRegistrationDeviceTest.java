package cn.aweffr.webrtcscreencast.tv.session;

import static org.junit.Assert.assertEquals;

import androidx.test.ext.junit.runners.AndroidJUnit4;
import cn.aweffr.webrtcscreencast.tv.signaling.SignalingCodec;
import cn.aweffr.webrtcscreencast.tv.signaling.SignalingMessage;
import java.time.Instant;
import org.junit.Test;
import org.junit.runner.RunWith;

@RunWith(AndroidJUnit4.class)
public final class ReceiverRegistrationDeviceTest {
  @Test
  public void parsesGoServerTimestampWithLocalOffsetAndMicroseconds() {
    SignalingMessage message = SignalingCodec.decode("""
        {"version":1,"message_id":"server-1","type":"receiver.registered",
        "payload":{"session_id":"session-1","pairing_code":"01ABCD23",
        "expires_at":"2026-07-16T01:45:18.759902+08:00"}}
        """);

    assertEquals(
        Instant.parse("2026-07-15T17:45:18.759902Z"),
        ReceiverController.parseRegistration(message).expiresAt());
  }
}
