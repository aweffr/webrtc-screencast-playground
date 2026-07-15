package cn.aweffr.webrtcscreencast.tv.signaling;

import static org.junit.Assert.assertEquals;
import static org.junit.Assert.assertFalse;
import static org.junit.Assert.assertThrows;

import org.json.JSONObject;
import org.junit.Test;

public final class SignalingCodecTest {
  @Test
  public void receiverRegisteredDecodesWithProtocolFieldNames() {
    SignalingMessage message = SignalingCodec.decode("""
        {
          "version": 1,
          "message_id": "server-1",
          "type": "receiver.registered",
          "payload": {
            "session_id": "session-1",
            "pairing_code": "AB12CD34",
            "expires_at": "2026-07-16T00:00:00Z"
          }
        }
        """);

    assertEquals(SignalingMessage.Type.RECEIVER_REGISTERED, message.type());
    assertEquals("session-1", message.payloadString("session_id"));
    assertEquals("AB12CD34", message.payloadString("pairing_code"));
  }

  @Test
  public void outboundReceiverRegisterUsesAnEmptyPayload() throws Exception {
    String encoded = SignalingCodec.encode(SignalingMessage.receiverRegister("android-1"));
    JSONObject envelope = new JSONObject(encoded);

    assertEquals(1, envelope.getInt("version"));
    assertEquals("android-1", envelope.getString("message_id"));
    assertEquals("receiver.register", envelope.getString("type"));
    assertEquals(0, envelope.getJSONObject("payload").length());
  }

  @Test
  public void unknownEnvelopeOrPayloadFieldsAreRejected() {
    assertThrows(IllegalArgumentException.class, () -> SignalingCodec.decode("""
        {"version":1,"message_id":"x","type":"ice.complete","payload":{},"extra":true}
        """));
    assertThrows(IllegalArgumentException.class, () -> SignalingCodec.decode("""
        {"version":1,"message_id":"x","type":"ice.complete","payload":{"extra":true}}
        """));
    assertThrows(IllegalArgumentException.class, () -> SignalingCodec.decode("""
        {"version":2,"message_id":"x","type":"ice.complete","payload":{}}
        """));
  }

  @Test
  public void diagnosticTextNeverContainsSdpOrCandidate() {
    String sdp = "v=0 secret-sdp";
    String candidate = "candidate:secret-address";
    SignalingMessage offer = SignalingCodec.decode(String.format(
        "{\"version\":1,\"message_id\":\"x\",\"type\":\"sdp.offer\","
            + "\"payload\":{\"sdp\":%s}}", JSONObject.quote(sdp)));
    SignalingMessage ice = SignalingCodec.decode(String.format(
        "{\"version\":1,\"message_id\":\"y\",\"type\":\"ice.candidate\","
            + "\"payload\":{\"candidate\":%s,\"sdp_mid\":\"0\","
            + "\"sdp_mline_index\":0}}", JSONObject.quote(candidate)));

    assertFalse(offer.toString().contains(sdp));
    assertFalse(ice.toString().contains(candidate));
  }
}
