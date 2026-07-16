package cn.aweffr.webrtcscreencast.tv.signaling;

import java.util.Objects;
import java.util.concurrent.TimeUnit;
import okhttp3.OkHttpClient;
import okhttp3.Request;
import okhttp3.Response;
import okhttp3.WebSocket;
import okhttp3.WebSocketListener;

/** One-connection WebSocket transport; reconnect policy remains in ReceiverController. */
public final class SignalingClient implements AutoCloseable {
  public interface Listener {
    void onOpen();

    void onMessage(SignalingMessage message);

    void onClosed();

    void onFailure(Throwable error);
  }

  private final OkHttpClient httpClient;
  private final Listener listener;
  private WebSocket webSocket;
  private boolean closed;

  public SignalingClient(Listener listener) {
    this.listener = Objects.requireNonNull(listener, "listener");
    httpClient = new OkHttpClient.Builder()
        .readTimeout(0, TimeUnit.MILLISECONDS)
        .build();
  }

  public synchronized void connect(String url) {
    if (webSocket != null || closed) {
      throw new IllegalStateException("Signaling client already used");
    }
    Request request = new Request.Builder().url(url).build();
    webSocket = httpClient.newWebSocket(request, new WebSocketListener() {
      @Override
      public void onOpen(WebSocket socket, Response response) {
        listener.onOpen();
      }

      @Override
      public void onMessage(WebSocket socket, String text) {
        try {
          listener.onMessage(SignalingCodec.decode(text));
        } catch (RuntimeException error) {
          listener.onFailure(error);
        }
      }

      @Override
      public void onClosed(WebSocket socket, int code, String reason) {
        listener.onClosed();
      }

      @Override
      public void onFailure(WebSocket socket, Throwable error, Response response) {
        listener.onFailure(error);
      }
    });
  }

  public synchronized void send(SignalingMessage message) {
    if (webSocket == null || closed) {
      throw new IllegalStateException("Signaling client is not connected");
    }
    if (!webSocket.send(SignalingCodec.encode(message))) {
      throw new IllegalStateException("Signaling WebSocket rejected message");
    }
  }

  @Override
  public synchronized void close() {
    if (closed) {
      return;
    }
    closed = true;
    if (webSocket != null) {
      webSocket.close(1000, "receiver_cleanup");
      webSocket = null;
    }
    httpClient.dispatcher().executorService().shutdown();
    httpClient.connectionPool().evictAll();
  }
}
