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
  public static final class InitializationException extends IllegalStateException {
    private final String stage;

    private InitializationException(String stage, RuntimeException cause) {
      super("receiver_runtime_initialization_failed", cause);
      this.stage = stage;
    }

    public String stage() {
      return stage;
    }
  }

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
    EglBase createdEgl = EglBase.create();
    CastTuningController createdTuning = null;
    PeerConnectionFactory createdFactory = null;
    String stage = "cast_tuning_parse";
    try {
      CastTuningConfig tuningConfig = CastTuningConfig.fromJson(config.castTuningJson());
      stage = "cast_tuning_controller";
      createdTuning = new CastTuningController(tuningConfig);
      stage = "video_decoder_factory";
      VideoDecoderFactory decoderFactory =
          createdTuning.createVideoDecoderFactory(createdEgl.getEglBaseContext());
      stage = "peer_connection_factory";
      PeerConnectionFactory.Builder builder = PeerConnectionFactory.builder()
          .setVideoDecoderFactory(decoderFactory);
      createdFactory = createdTuning.configureFactory(builder)
          .createPeerConnectionFactory();
    } catch (RuntimeException error) {
      if (createdFactory != null) {
        createdFactory.dispose();
      }
      if (createdTuning != null) {
        createdTuning.close();
      }
      createdEgl.release();
      throw new InitializationException(stage, error);
    }
    eglBase = createdEgl;
    tuningController = createdTuning;
    peerConnectionFactory = createdFactory;
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
