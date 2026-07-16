package cn.aweffr.webrtcscreencast.tv.signaling;

import java.util.Collections;
import java.util.LinkedHashMap;
import java.util.Map;

/** Typed signaling envelope whose diagnostic text never exposes media negotiation payloads. */
public final class SignalingMessage {
  public enum Type {
    RECEIVER_REGISTER("receiver.register"),
    RECEIVER_REGISTERED("receiver.registered"),
    SENDER_JOIN("sender.join"),
    SESSION_PAIRED("session.paired"),
    SDP_OFFER("sdp.offer"),
    SDP_ANSWER("sdp.answer"),
    ICE_CANDIDATE("ice.candidate"),
    ICE_COMPLETE("ice.complete"),
    SESSION_HANGUP("session.hangup"),
    ERROR("error");

    private final String wireValue;

    Type(String wireValue) {
      this.wireValue = wireValue;
    }

    public String wireValue() {
      return wireValue;
    }

    static Type parse(String value) {
      for (Type type : values()) {
        if (type.wireValue.equals(value)) {
          return type;
        }
      }
      throw new IllegalArgumentException("unsupported signaling message type");
    }
  }

  private final String messageId;
  private final Type type;
  private final Map<String, Object> payload;

  SignalingMessage(String messageId, Type type, Map<String, Object> payload) {
    this.messageId = messageId;
    this.type = type;
    this.payload = Collections.unmodifiableMap(new LinkedHashMap<>(payload));
  }

  public static SignalingMessage receiverRegister(String messageId) {
    return new SignalingMessage(messageId, Type.RECEIVER_REGISTER, Map.of());
  }

  public static SignalingMessage sdpAnswer(String messageId, String sdp) {
    return new SignalingMessage(messageId, Type.SDP_ANSWER, Map.of("sdp", sdp));
  }

  public static SignalingMessage iceCandidate(
      String messageId, String candidate, String sdpMid, int sdpMLineIndex) {
    Map<String, Object> payload = new LinkedHashMap<>();
    payload.put("candidate", candidate);
    payload.put("sdp_mid", sdpMid);
    payload.put("sdp_mline_index", sdpMLineIndex);
    return new SignalingMessage(messageId, Type.ICE_CANDIDATE, payload);
  }

  public static SignalingMessage iceComplete(String messageId) {
    return new SignalingMessage(messageId, Type.ICE_COMPLETE, Map.of());
  }

  public static SignalingMessage sessionHangup(String messageId, String reason) {
    return new SignalingMessage(messageId, Type.SESSION_HANGUP, Map.of("reason", reason));
  }

  public String messageId() {
    return messageId;
  }

  public Type type() {
    return type;
  }

  Map<String, Object> payload() {
    return payload;
  }

  public String payloadString(String key) {
    Object value = payload.get(key);
    if (!(value instanceof String string)) {
      throw new IllegalArgumentException("payload field is not a string: " + key);
    }
    return string;
  }

  public int payloadInt(String key) {
    Object value = payload.get(key);
    if (!(value instanceof Number number)) {
      throw new IllegalArgumentException("payload field is not a number: " + key);
    }
    return number.intValue();
  }

  @Override
  public String toString() {
    return "SignalingMessage{messageId='" + messageId + "', type=" + type + "}";
  }
}
