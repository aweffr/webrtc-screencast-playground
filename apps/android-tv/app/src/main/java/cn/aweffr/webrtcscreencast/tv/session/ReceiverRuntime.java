package cn.aweffr.webrtcscreencast.tv.session;

import android.content.Context;
import cn.aweffr.webrtcscreencast.tv.config.ReferenceRuntimeConfig;
import java.util.Objects;
import org.webrtc.CastTuningConfig;
import org.webrtc.CastTuningController;
import org.webrtc.CastTuningSnapshot;
import org.webrtc.EglBase;
import org.webrtc.PeerConnectionFactory;
import org.webrtc.VideoDecoderFactory;

/** App-lifetime native runtime. Per-cast PeerConnections are owned by WebRtcReceiverSession. */
public final class ReceiverRuntime implements AutoCloseable {
  private final EglBase eglBase;
  private final CastTuningController tuningController;
  private final PeerConnectionFactory peerConnectionFactory;
  private boolean closed;

  public ReceiverRuntime(Context context, ReferenceRuntimeConfig config) {
    Objects.requireNonNull(context, "context");
    Objects.requireNonNull(config, "config").validate();
    PeerConnectionFactory.initialize(
        PeerConnectionFactory.InitializationOptions.builder(context.getApplicationContext())
            .setEnableInternalTracer(false)
            .createInitializationOptions());
    eglBase = EglBase.create();
    tuningController = new CastTuningController(CastTuningConfig.fromJson(config.castTuningJson()));
    VideoDecoderFactory decoderFactory =
        tuningController.createVideoDecoderFactory(eglBase.getEglBaseContext());
    PeerConnectionFactory.Builder builder = PeerConnectionFactory.builder()
        .setVideoDecoderFactory(decoderFactory);
    peerConnectionFactory = tuningController.configureFactory(builder)
        .createPeerConnectionFactory();
  }

  public PeerConnectionFactory peerConnectionFactory() {
    checkOpen();
    return peerConnectionFactory;
  }

  public EglBase.Context eglContext() {
    checkOpen();
    return eglBase.getEglBaseContext();
  }

  public CastTuningController tuningController() {
    checkOpen();
    return tuningController;
  }

  public CastTuningSnapshot tuningSnapshot() {
    checkOpen();
    return tuningController.snapshot();
  }

  private void checkOpen() {
    if (closed) {
      throw new IllegalStateException("Receiver runtime is closed");
    }
  }

  @Override
  public void close() {
    if (closed) {
      return;
    }
    closed = true;
    peerConnectionFactory.dispose();
    tuningController.close();
    eglBase.release();
  }
}
