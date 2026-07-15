package cn.aweffr.webrtcscreencast.tv.signaling;

import java.util.LinkedHashMap;
import java.util.LinkedHashSet;
import java.util.Iterator;
import java.util.Map;
import java.util.Set;
import org.json.JSONException;
import org.json.JSONObject;

/** Strict protocol-v1 JSON codec shared by the Android Receiver signaling path. */
public final class SignalingCodec {
  private static final int PROTOCOL_VERSION = 1;
  private static final Set<String> ENVELOPE_FIELDS =
      Set.of("version", "message_id", "type", "payload");

  private SignalingCodec() {}

  public static SignalingMessage decode(String encoded) {
    try {
      JSONObject envelope = new JSONObject(encoded);
      requireExactFields(envelope, ENVELOPE_FIELDS);
      if (envelope.getInt("version") != PROTOCOL_VERSION) {
        throw new IllegalArgumentException("unsupported signaling protocol version");
      }
      String messageId = requiredString(envelope, "message_id", 64);
      SignalingMessage.Type type = SignalingMessage.Type.parse(
          requiredString(envelope, "type", 64));
      JSONObject payload = envelope.getJSONObject("payload");
      validatePayload(type, payload);
      Map<String, Object> values = new LinkedHashMap<>();
      for (String key : fieldSet(payload)) {
        values.put(key, payload.get(key));
      }
      return new SignalingMessage(messageId, type, values);
    } catch (JSONException error) {
      throw new IllegalArgumentException("invalid signaling JSON", error);
    }
  }

  public static String encode(SignalingMessage message) {
    try {
      validateMessageId(message.messageId());
      JSONObject payload = new JSONObject();
      for (Map.Entry<String, Object> entry : message.payload().entrySet()) {
        payload.put(entry.getKey(), entry.getValue());
      }
      validatePayload(message.type(), payload);
      return new JSONObject()
          .put("version", PROTOCOL_VERSION)
          .put("message_id", message.messageId())
          .put("type", message.type().wireValue())
          .put("payload", payload)
          .toString();
    } catch (JSONException error) {
      throw new IllegalArgumentException("unable to encode signaling JSON", error);
    }
  }

  private static void validatePayload(SignalingMessage.Type type, JSONObject payload)
      throws JSONException {
    switch (type) {
      case RECEIVER_REGISTER, ICE_COMPLETE -> requireExactFields(payload, Set.of());
      case RECEIVER_REGISTERED -> {
        requireExactFields(payload, Set.of("session_id", "pairing_code", "expires_at"));
        requiredString(payload, "session_id", 128);
        requiredString(payload, "pairing_code", 16);
        requiredString(payload, "expires_at", 64);
      }
      case SENDER_JOIN -> {
        requireExactFields(payload, Set.of("pairing_code"));
        requiredString(payload, "pairing_code", 16);
      }
      case SESSION_PAIRED -> {
        requireExactFields(payload, Set.of("session_id", "role"));
        requiredString(payload, "session_id", 128);
        String role = requiredString(payload, "role", 16);
        if (!("sender".equals(role) || "receiver".equals(role))) {
          throw new IllegalArgumentException("invalid paired role");
        }
      }
      case SDP_OFFER, SDP_ANSWER -> {
        requireExactFields(payload, Set.of("sdp"));
        requiredString(payload, "sdp", 128 * 1024);
      }
      case ICE_CANDIDATE -> {
        requireExactFields(payload, Set.of("candidate", "sdp_mid", "sdp_mline_index"));
        requiredString(payload, "candidate", 16 * 1024);
        requiredStringAllowEmpty(payload, "sdp_mid", 256);
        int line = payload.getInt("sdp_mline_index");
        if (line < 0) {
          throw new IllegalArgumentException("invalid ICE m-line index");
        }
      }
      case SESSION_HANGUP -> {
        requireOnlyFields(payload, Set.of("reason"));
        if (payload.has("reason")) {
          requiredStringAllowEmpty(payload, "reason", 256);
        }
      }
      case ERROR -> {
        requireOnlyFields(payload, Set.of("code", "message", "related_message_id"));
        requiredString(payload, "code", 64);
        requiredString(payload, "message", 512);
        if (payload.has("related_message_id")) {
          requiredStringAllowEmpty(payload, "related_message_id", 64);
        }
      }
    }
  }

  private static String requiredString(JSONObject object, String key, int maxLength)
      throws JSONException {
    String value = requiredStringAllowEmpty(object, key, maxLength);
    if (value.isEmpty()) {
      throw new IllegalArgumentException("payload field is empty: " + key);
    }
    return value;
  }

  private static String requiredStringAllowEmpty(
      JSONObject object, String key, int maxLength) throws JSONException {
    Object raw = object.get(key);
    if (!(raw instanceof String value) || value.length() > maxLength) {
      throw new IllegalArgumentException("invalid string field: " + key);
    }
    return value;
  }

  private static void validateMessageId(String messageId) {
    if (messageId == null || messageId.isEmpty() || messageId.length() > 64) {
      throw new IllegalArgumentException("invalid signaling message id");
    }
  }

  private static void requireExactFields(JSONObject object, Set<String> fields) {
    if (!fieldSet(object).equals(fields)) {
      throw new IllegalArgumentException("unexpected or missing JSON fields");
    }
  }

  private static void requireOnlyFields(JSONObject object, Set<String> fields) {
    if (!fields.containsAll(fieldSet(object))) {
      throw new IllegalArgumentException("unexpected JSON field");
    }
  }

  private static Set<String> fieldSet(JSONObject object) {
    Set<String> fields = new LinkedHashSet<>();
    Iterator<String> keys = object.keys();
    while (keys.hasNext()) {
      fields.add(keys.next());
    }
    return fields;
  }
}
