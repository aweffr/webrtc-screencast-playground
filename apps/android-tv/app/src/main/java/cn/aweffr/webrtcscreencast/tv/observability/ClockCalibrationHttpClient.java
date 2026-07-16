package cn.aweffr.webrtcscreencast.tv.observability;

import android.os.SystemClock;
import java.io.IOException;
import java.net.URI;
import java.net.URISyntaxException;
import java.util.ArrayList;
import java.util.List;
import java.util.Objects;
import java.util.concurrent.TimeUnit;
import okhttp3.OkHttpClient;
import okhttp3.Request;
import okhttp3.Response;
import okhttp3.ResponseBody;
import org.json.JSONException;
import org.json.JSONObject;

/** Performs bounded clock calibration without sharing signaling credentials or payloads. */
public final class ClockCalibrationHttpClient implements AutoCloseable {
  private static final int MAX_SAMPLES = 20;

  private final OkHttpClient client;
  private final boolean ownsClient;

  public ClockCalibrationHttpClient() {
    this(new OkHttpClient.Builder().callTimeout(2, TimeUnit.SECONDS).build(), true);
  }

  ClockCalibrationHttpClient(OkHttpClient client) {
    this(client, false);
  }

  private ClockCalibrationHttpClient(OkHttpClient client, boolean ownsClient) {
    this.client = Objects.requireNonNull(client, "client");
    this.ownsClient = ownsClient;
  }

  public ClockCalibration calibrate(String signalingUrl, int sampleCount) throws IOException {
    if (sampleCount < 1 || sampleCount > MAX_SAMPLES) {
      throw new IllegalArgumentException("sampleCount must be between 1 and " + MAX_SAMPLES);
    }

    Request request = new Request.Builder()
        .url(endpoint(signalingUrl))
        .header("Accept", "application/json")
        .header("Cache-Control", "no-cache")
        .get()
        .build();
    List<ClockCalibration.Sample> samples = new ArrayList<>(sampleCount);
    for (int index = 0; index < sampleCount; index++) {
      long startedNs = SystemClock.elapsedRealtimeNanos();
      long serverUnixNs;
      try (Response response = client.newCall(request).execute()) {
        if (response.code() != 200) {
          throw new IOException("clock endpoint returned HTTP " + response.code());
        }
        ResponseBody body = response.body();
        if (body == null) {
          throw new IOException("clock endpoint returned an empty body");
        }
        String encoded = body.string();
        long finishedNs = SystemClock.elapsedRealtimeNanos();
        serverUnixNs = parseServerUnixNs(encoded);
        samples.add(new ClockCalibration.Sample(startedNs, finishedNs, serverUnixNs));
      }
    }
    return ClockCalibration.choose(samples);
  }

  static long parseServerUnixNs(String encoded) throws IOException {
    try {
      JSONObject response = new JSONObject(encoded);
      if (response.length() != 2
          || response.getInt("schema_version") != 1
          || !response.has("server_unix_ns")) {
        throw new IOException("clock endpoint response does not match schema 1");
      }
      long serverUnixNs = response.getLong("server_unix_ns");
      if (serverUnixNs <= 0) {
        throw new IOException("clock endpoint returned a non-positive timestamp");
      }
      return serverUnixNs;
    } catch (JSONException error) {
      throw new IOException("clock endpoint returned invalid JSON", error);
    }
  }

  static String endpoint(String signalingUrl) {
    Objects.requireNonNull(signalingUrl, "signalingUrl");
    URI signaling;
    try {
      signaling = new URI(signalingUrl);
    } catch (URISyntaxException error) {
      throw new IllegalArgumentException("invalid signaling URL", error);
    }
    String scheme = signaling.getScheme();
    String httpScheme;
    if ("ws".equalsIgnoreCase(scheme)) {
      httpScheme = "http";
    } else if ("wss".equalsIgnoreCase(scheme)) {
      httpScheme = "https";
    } else {
      throw new IllegalArgumentException("signaling URL must use ws or wss");
    }
    if (signaling.getHost() == null || signaling.getUserInfo() != null) {
      throw new IllegalArgumentException("signaling URL must contain a host and no user info");
    }
    try {
      return new URI(
          httpScheme,
          null,
          signaling.getHost(),
          signaling.getPort(),
          "/clock",
          null,
          null).toString();
    } catch (URISyntaxException error) {
      throw new IllegalArgumentException("invalid signaling URL", error);
    }
  }

  @Override
  public void close() {
    if (!ownsClient) {
      return;
    }
    client.dispatcher().executorService().shutdown();
    client.connectionPool().evictAll();
  }
}
