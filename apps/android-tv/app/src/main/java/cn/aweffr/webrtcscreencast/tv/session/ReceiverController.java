package cn.aweffr.webrtcscreencast.tv.session;

import android.content.Context;
import android.os.Handler;
import android.os.Looper;
import android.os.SystemClock;
import cn.aweffr.webrtcscreencast.tv.config.ReferenceRuntimeConfig;
import cn.aweffr.webrtcscreencast.tv.observability.ClockCalibration;
import cn.aweffr.webrtcscreencast.tv.observability.ClockCalibrationHttpClient;
import cn.aweffr.webrtcscreencast.tv.observability.AndroidMarkerProbe;
import cn.aweffr.webrtcscreencast.tv.observability.ReceiverAutomationChannel;
import cn.aweffr.webrtcscreencast.tv.observability.ReceiverMetricsRecorder;
import cn.aweffr.webrtcscreencast.tv.observability.RtcStatsNormalizer;
import cn.aweffr.webrtcscreencast.tv.signaling.SignalingClient;
import cn.aweffr.webrtcscreencast.tv.signaling.SignalingMessage;
import java.io.IOException;
import java.time.Duration;
import java.time.Instant;
import java.time.OffsetDateTime;
import java.util.ArrayList;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Locale;
import java.util.Map;
import java.util.Objects;
import java.util.UUID;
import java.util.concurrent.ScheduledExecutorService;
import java.util.concurrent.ScheduledFuture;
import java.util.concurrent.Executors;
import java.util.concurrent.RejectedExecutionException;
import java.util.concurrent.TimeUnit;
import java.util.concurrent.atomic.AtomicBoolean;
import org.webrtc.CastTuningSnapshot;
import org.webrtc.EglBase;
import org.webrtc.IceCandidate;
import org.webrtc.PeerConnection;
import org.webrtc.RTCStatsReport;
import org.webrtc.VideoSink;
import org.webrtc.VideoTrack;

/** Serializes receiver registration, one-cast WebRTC ownership, retries, and safe evidence. */
public final class ReceiverController implements ReceiverSessionController {
  record Registration(String sessionId, String pairingCode, Instant expiresAt) {}

  static final class ProtocolHandlingException extends RuntimeException {
    private final String code;

    ProtocolHandlingException(String code, RuntimeException cause) {
      super(code, cause);
      this.code = code;
    }

    String code() {
      return code;
    }
  }

  public record Presentation(
      ReceiverStateMachine.State state,
      String pairingCode,
      String errorCode,
      RtcStatsNormalizer.Sample latestStats) {}

  public interface Observer {
    void onPresentation(Presentation presentation);
  }

  private record PendingIce(String candidate, String mid, int line) {}

  private final ReferenceRuntimeConfig config;
  private final Observer observer;
  private final Handler mainHandler;
  private final ScheduledExecutorService executor;
  private final ReceiverStateMachine stateMachine = new ReceiverStateMachine();
  private final ReceiverRuntime runtime;
  private final ReceiverAutomationChannel automation;
  private final ReceiverMetricsRecorder metrics;
  private final RtcStatsNormalizer statsNormalizer;
  private final List<PendingIce> pendingRemoteIce = new ArrayList<>();
  private final AtomicBoolean closeRequested = new AtomicBoolean();

  private SignalingClient signaling;
  private WebRtcReceiverSession session;
  private AndroidMarkerProbe markerProbe;
  private VideoSink renderer;
  private ClockCalibration clockCalibration;
  private ScheduledFuture<?> expiryTimer;
  private ScheduledFuture<?> retryTimer;
  private ScheduledFuture<?> statsTimer;
  private String pairingCode;
  private String sessionId;
  private String errorCode;
  private RtcStatsNormalizer.Sample latestStats;
  private boolean remoteDescriptionReady;
  private boolean baselineMode;
  private boolean closed;
  private int generation;
  private long signalingStartedNs;
  private long pairedNs;
  private long offerReceivedNs;

  public ReceiverController(
      Context context,
      ReferenceRuntimeConfig config,
      Observer observer) throws IOException {
    Context appContext = Objects.requireNonNull(context, "context").getApplicationContext();
    this.config = Objects.requireNonNull(config, "config");
    this.observer = Objects.requireNonNull(observer, "observer");
    this.config.validate();
    mainHandler = new Handler(Looper.getMainLooper());
    executor = Executors.newSingleThreadScheduledExecutor(runnable -> {
      Thread thread = new Thread(runnable, "receiver-controller");
      thread.setDaemon(true);
      return thread;
    });
    metrics = new ReceiverMetricsRecorder(appContext);
    automation = new ReceiverAutomationChannel(
        new java.io.File(appContext.getFilesDir(), "automation"));
    metrics.record("receiver_runtime_initializing", Map.of(
        "config_hash", config.redactedHash(),
        "ice_profile", config.iceProfile().wireValue()));
    try {
      runtime = new ReceiverRuntime(appContext, config);
    } catch (RuntimeException error) {
      Map<String, Object> failure = new LinkedHashMap<>();
      failure.put("error_type", error.getClass().getSimpleName());
      if (error instanceof ReceiverRuntime.InitializationException initialization) {
        failure.put("stage", initialization.stage());
      }
      metrics.record("receiver_runtime_initialization_failed", failure);
      metrics.close();
      executor.shutdownNow();
      throw error;
    }
    statsNormalizer = new RtcStatsNormalizer(config.iceProfile());
    CastTuningSnapshot tuning = runtime.tuningSnapshot();
    Map<String, Object> fields = new LinkedHashMap<>();
    fields.put("config_hash", config.redactedHash());
    fields.put("ice_profile", config.iceProfile().wireValue());
    fields.put("tuning_hash", tuning.effectiveConfigHash);
    fields.put("tuning_revision", tuning.revision);
    fields.put("decoder_low_latency", runtime.tuningController().androidDecoderLowLatencyEnabled());
    metrics.record("receiver_runtime_initialized", fields);
  }

  public EglBase.Context eglContext() {
    return runtime.eglContext();
  }

  public String runId() {
    return metrics.runId();
  }

  public void start(VideoSink renderer, boolean baselineMode) {
    Objects.requireNonNull(renderer, "renderer");
    if (closeRequested.get()) {
      return;
    }
    executor.execute(() -> {
      if (closed || stateMachine.state() != ReceiverStateMachine.State.STOPPED) {
        return;
      }
      this.renderer = renderer;
      this.baselineMode = baselineMode;
      stateMachine.reduce(ReceiverStateMachine.Event.start());
      publish();
      calibrateClockThenConnect();
    });
  }

  public void stop() {
    if (closeRequested.get()) {
      return;
    }
    executor.execute(() -> {
      if (closed) {
        return;
      }
      apply(stateMachine.reduce(ReceiverStateMachine.Event.stop()));
      publish();
    });
  }

  public void retry() {
    if (closeRequested.get()) {
      return;
    }
    executor.execute(() -> {
      if (closed || stateMachine.state() != ReceiverStateMachine.State.ERROR) {
        return;
      }
      errorCode = null;
      ReceiverStateMachine.Transition transition =
          stateMachine.reduce(ReceiverStateMachine.Event.manualRetry());
      cleanupConnection();
      if (transition.state() == ReceiverStateMachine.State.CONNECTING) {
        publish();
        calibrateClockThenConnect();
      }
    });
  }

  private void calibrateClockThenConnect() {
    try (ClockCalibrationHttpClient client = new ClockCalibrationHttpClient()) {
      clockCalibration = client.calibrate(config.signalingUrl(), 5);
      metrics.record("clock_calibration", Map.of(
          "sample_count", 5,
          "offset_ns", clockCalibration.offsetNs(),
          "round_trip_ns", clockCalibration.roundTripNs(),
          "uncertainty_ns", clockCalibration.uncertaintyNs()));
    } catch (IOException | RuntimeException error) {
      metrics.record("clock_calibration_unavailable", Map.of(
          "error_type", error.getClass().getSimpleName()));
      if (baselineMode) {
        fatal(ReceiverStateMachine.FatalError.INVALID_CONFIG, "clock_calibration_unavailable");
        return;
      }
    }
    connect();
  }

  private void connect() {
    if (stateMachine.state() != ReceiverStateMachine.State.CONNECTING) {
      return;
    }
    final int callbackGeneration = generation;
    signalingStartedNs = SystemClock.elapsedRealtimeNanos();
    metrics.record("signaling_connect_started");
    signaling = new SignalingClient(new SignalingClient.Listener() {
      @Override
      public void onOpen() {
        post(callbackGeneration, ReceiverController.this::onSignalingOpen);
      }

      @Override
      public void onMessage(SignalingMessage message) {
        post(callbackGeneration, () -> onSignalingMessage(message));
      }

      @Override
      public void onClosed() {
        post(callbackGeneration, () -> recover("signaling_closed"));
      }

      @Override
      public void onFailure(Throwable error) {
        post(callbackGeneration, () -> recover("signaling_failure"));
      }
    });
    try {
      signaling.connect(config.signalingUrl());
    } catch (RuntimeException error) {
      recover("signaling_connect_failed");
    }
    publish();
  }

  private void onSignalingOpen() {
    if (stateMachine.state() != ReceiverStateMachine.State.CONNECTING) {
      return;
    }
    metrics.record("signaling_connected", Map.of(
        "duration_ms", elapsedMs(signalingStartedNs)));
    apply(stateMachine.reduce(ReceiverStateMachine.Event.connected()));
  }

  private void onSignalingMessage(SignalingMessage message) {
    try {
      switch (message.type()) {
        case RECEIVER_REGISTERED -> onRegistered(message);
        case SESSION_PAIRED -> onPaired(message);
        case SDP_OFFER -> onOffer(message);
        case ICE_CANDIDATE -> onRemoteIce(message);
        case ICE_COMPLETE -> metrics.record("remote_ice_complete");
        case SESSION_HANGUP -> recoverWith(ReceiverStateMachine.Event.hangup(), "session_hangup");
        case ERROR -> recover("signaling_error");
        default -> recover("unexpected_signaling_message");
      }
    } catch (ProtocolHandlingException error) {
      recover(error.code());
    } catch (RuntimeException error) {
      recover("invalid_signaling_message");
    }
  }

  private void onRegistered(SignalingMessage message) {
    if (stateMachine.state() != ReceiverStateMachine.State.REGISTERING) {
      throw new ProtocolHandlingException(
          "receiver_registration_state_invalid",
          new IllegalStateException("receiver_registered_in_wrong_state"));
    }
    Registration registration = parseRegistration(message);
    sessionId = registration.sessionId();
    pairingCode = registration.pairingCode();
    try {
      apply(stateMachine.reduce(ReceiverStateMachine.Event.registered()));
      metrics.record("receiver_registered", Map.of(
          "session_id", sessionId,
          "duration_ms", elapsedMs(signalingStartedNs)));
      try {
        automation.publishPairingCode(sessionId, pairingCode);
      } catch (IOException error) {
        throw new ProtocolHandlingException(
            "receiver_automation_channel_failed", new IllegalStateException(error));
      }
      long delayMs = Math.max(
          0L, Duration.between(Instant.now(), registration.expiresAt()).toMillis());
      int timerGeneration = generation;
      expiryTimer = executor.schedule(() -> {
        if (timerGeneration == generation) {
          recoverWith(ReceiverStateMachine.Event.expired(), "pairing_expired");
        }
      }, delayMs, TimeUnit.MILLISECONDS);
      publish();
    } catch (RuntimeException error) {
      throw new ProtocolHandlingException("receiver_registration_commit_failed", error);
    }
  }

  static Registration parseRegistration(SignalingMessage message) {
    String parsedSessionId;
    String parsedPairingCode;
    try {
      parsedSessionId = message.payloadString("session_id");
      parsedPairingCode = message.payloadString("pairing_code");
    } catch (RuntimeException error) {
      throw new ProtocolHandlingException("receiver_registration_payload_invalid", error);
    }
    try {
      return new Registration(
          parsedSessionId,
          parsedPairingCode,
          OffsetDateTime.parse(message.payloadString("expires_at")).toInstant());
    } catch (RuntimeException error) {
      throw new ProtocolHandlingException("receiver_registration_expiry_invalid", error);
    }
  }

  private void onPaired(SignalingMessage message) {
    if (stateMachine.state() != ReceiverStateMachine.State.WAITING_CODE
        || !"receiver".equals(message.payloadString("role"))
        || !Objects.equals(sessionId, message.payloadString("session_id"))) {
      throw new IllegalStateException("session_paired_mismatch");
    }
    cancel(expiryTimer);
    expiryTimer = null;
    automation.clear();
    pairingCode = null;
    pairedNs = SystemClock.elapsedRealtimeNanos();
    metrics.record("session_paired", Map.of(
        "session_id", sessionId,
        "duration_ms", elapsedMs(signalingStartedNs)));
    apply(stateMachine.reduce(ReceiverStateMachine.Event.paired()));
  }

  private void onOffer(SignalingMessage message) {
    if (stateMachine.state() != ReceiverStateMachine.State.PAIRED) {
      throw new IllegalStateException("offer_in_wrong_state");
    }
    offerReceivedNs = SystemClock.elapsedRealtimeNanos();
    String offer = message.payloadString("sdp");
    apply(stateMachine.reduce(ReceiverStateMachine.Event.offerReceived()));
    metrics.record("sdp_offer_received", Map.of("duration_ms", elapsedMs(pairedNs)));
    session.applyOffer(offer);
  }

  private void onRemoteIce(SignalingMessage message) {
    ReceiverStateMachine.State state = stateMachine.state();
    if (state != ReceiverStateMachine.State.NEGOTIATING
        && state != ReceiverStateMachine.State.PLAYING) {
      throw new IllegalStateException("remote_ice_in_wrong_state");
    }
    PendingIce ice = new PendingIce(
        message.payloadString("candidate"),
        message.payloadString("sdp_mid"),
        message.payloadInt("sdp_mline_index"));
    apply(stateMachine.reduce(ReceiverStateMachine.Event.remoteIce()));
    if (remoteDescriptionReady) {
      addRemoteIce(ice);
    } else {
      pendingRemoteIce.add(ice);
    }
  }

  private void createPeer() {
    final int callbackGeneration = generation;
    try {
      markerProbe = baselineMode
          ? new AndroidMarkerProbe(metrics, Objects.requireNonNull(clockCalibration))
          : null;
      session = new WebRtcReceiverSession(runtime, config, renderer, markerProbe,
          new WebRtcReceiverSession.Listener() {
            @Override
            public void onLocalAnswer(String sdp) {
              post(callbackGeneration, () -> ReceiverController.this.onLocalAnswer(sdp));
            }

            @Override
            public void onLocalIceCandidate(IceCandidate candidate) {
              post(callbackGeneration, () -> sendLocalIce(candidate));
            }

            @Override
            public void onIceGatheringComplete() {
              post(callbackGeneration, ReceiverController.this::sendIceComplete);
            }

            @Override
            public void onRemoteVideoTrack(VideoTrack track) {
              post(callbackGeneration, ReceiverController.this::onRemoteTrack);
            }

            @Override
            public void onConnectionState(PeerConnection.PeerConnectionState state) {
              post(callbackGeneration,
                  () -> ReceiverController.this.onPeerConnectionState(state));
            }

            @Override
            public void onNegotiationStage(String stage) {
              post(callbackGeneration, () -> metrics.record(
                  "receiver_negotiation_stage", Map.of("stage", stage)));
            }

            @Override
            public void onFailure(String code, String message) {
              post(callbackGeneration, () -> {
                metrics.record("receiver_session_failure", Map.of(
                    "code", code,
                    "message", message == null ? "" : message));
                recover(code);
              });
            }
          });
      metrics.record("peer_connection_created");
    } catch (SelectedVideoCodecPolicy.CodecUnavailableException error) {
      fatal(ReceiverStateMachine.FatalError.CODEC_UNAVAILABLE, error.getMessage());
    } catch (RuntimeException error) {
      recover("peer_connection_creation_failed");
    }
  }

  private void onLocalAnswer(String sdp) {
    if (stateMachine.state() != ReceiverStateMachine.State.NEGOTIATING
        && stateMachine.state() != ReceiverStateMachine.State.PLAYING) {
      return;
    }
    remoteDescriptionReady = true;
    apply(stateMachine.reduce(ReceiverStateMachine.Event.answerReady()));
    if (!send(SignalingMessage.sdpAnswer(nextMessageId(), sdp))) {
      return;
    }
    metrics.record("sdp_answer_sent", Map.of("duration_ms", elapsedMs(offerReceivedNs)));
    for (PendingIce ice : pendingRemoteIce) {
      addRemoteIce(ice);
    }
    pendingRemoteIce.clear();
  }

  private void addRemoteIce(PendingIce ice) {
    if (session == null) {
      return;
    }
    try {
      session.addRemoteIceCandidate(ice.candidate(), ice.mid(), ice.line());
      metrics.record("remote_ice_added");
    } catch (RuntimeException error) {
      recover("add_remote_ice_failed");
    }
  }

  private void sendLocalIce(IceCandidate candidate) {
    if (signaling == null || candidate == null) {
      return;
    }
    if (send(SignalingMessage.iceCandidate(
        nextMessageId(), candidate.sdp, candidate.sdpMid, candidate.sdpMLineIndex))) {
      metrics.record("local_ice_sent");
    }
  }

  private void sendIceComplete() {
    if (signaling != null) {
      if (send(SignalingMessage.iceComplete(nextMessageId()))) {
        metrics.record("local_ice_complete");
      }
    }
  }

  private void onRemoteTrack() {
    if (stateMachine.state() != ReceiverStateMachine.State.NEGOTIATING) {
      return;
    }
    apply(stateMachine.reduce(ReceiverStateMachine.Event.remoteTrack()));
    metrics.record("remote_video_playing", Map.of(
        "negotiation_ms", elapsedMs(offerReceivedNs)));
    scheduleStats();
    publish();
  }

  private void onPeerConnectionState(PeerConnection.PeerConnectionState state) {
    metrics.record("peer_connection_state", Map.of(
        "state", state.name().toLowerCase(Locale.ROOT)));
    if (state == PeerConnection.PeerConnectionState.FAILED
        || state == PeerConnection.PeerConnectionState.DISCONNECTED
        || state == PeerConnection.PeerConnectionState.CLOSED) {
      recover("peer_connection_" + state.name().toLowerCase(Locale.ROOT));
    }
  }

  private void scheduleStats() {
    cancel(statsTimer);
    int callbackGeneration = generation;
    statsTimer = executor.scheduleWithFixedDelay(() -> {
      if (callbackGeneration != generation || session == null) {
        return;
      }
      WebRtcReceiverSession current = session;
      current.collectStats(report -> post(callbackGeneration, () -> recordStats(report)));
    }, 0L, 1L, TimeUnit.SECONDS);
  }

  private void recordStats(RTCStatsReport report) {
    latestStats = statsNormalizer.normalize((long) report.getTimestampUs(), report.getStatsMap());
    Map<String, Object> fields = new LinkedHashMap<>();
    RtcStatsNormalizer.InboundVideo inbound = latestStats.inbound();
    if (inbound != null) {
      put(fields, "bytes_received", inbound.bytesReceived());
      put(fields, "packets_received", inbound.packetsReceived());
      put(fields, "packets_lost", inbound.packetsLost());
      put(fields, "frames_received", inbound.framesReceived());
      put(fields, "frames_decoded", inbound.framesDecoded());
      put(fields, "frames_dropped", inbound.framesDropped());
      put(fields, "key_frames_decoded", inbound.keyFramesDecoded());
      put(fields, "qp_sum", inbound.qpSum());
      put(fields, "bitrate_bps", inbound.bitrateBps());
      put(fields, "jitter_ms", inbound.jitterMs());
      put(fields, "decode_time_ms", inbound.totalDecodeTimeMs());
      put(fields, "inter_frame_delay_ms", inbound.totalInterFrameDelayMs());
      put(fields, "frames_per_second", inbound.framesPerSecond());
      put(fields, "frame_width", inbound.frameWidth());
      put(fields, "frame_height", inbound.frameHeight());
      put(fields, "decoder", inbound.decoderImplementation());
      put(fields, "codec", inbound.codecMimeType());
    }
    RtcStatsNormalizer.SelectedPath path = latestStats.selectedPath();
    fields.put("path_status", path.status().name().toLowerCase(Locale.ROOT));
    put(fields, "local_path_type", path.localCandidateType());
    put(fields, "remote_path_type", path.remoteCandidateType());
    put(fields, "path_protocol", path.protocol());
    metrics.record("rtc_stats", fields);
    publish();
  }

  private void apply(ReceiverStateMachine.Transition transition) {
    for (ReceiverStateMachine.Command command : transition.commands()) {
      switch (command) {
        case CONNECT -> connect();
        case REGISTER -> {
          if (send(SignalingMessage.receiverRegister(nextMessageId()))) {
            metrics.record("receiver_register_sent");
          }
        }
        case CREATE_PEER -> createPeer();
        case CLEANUP -> cleanupConnection();
        case SCHEDULE_RETRY -> scheduleRetry(transition.retryDelaySeconds());
        case SHOW_ERROR -> publish();
        case APPLY_OFFER, SEND_ANSWER, ADD_ICE -> {
          // Payload-bearing operations are executed by the event handlers that own the payload.
        }
      }
    }
    publish();
  }

  private void scheduleRetry(long delaySeconds) {
    int timerGeneration = generation;
    retryTimer = executor.schedule(() -> {
      if (timerGeneration != generation || closed) {
        return;
      }
      apply(stateMachine.reduce(ReceiverStateMachine.Event.retryTimer()));
    }, delaySeconds, TimeUnit.SECONDS);
    metrics.record("receiver_retry_scheduled", Map.of("delay_seconds", delaySeconds));
  }

  private void recover(String code) {
    recoverWith(ReceiverStateMachine.Event.recoverableFailure(), code);
  }

  private void recoverWith(ReceiverStateMachine.Event event, String code) {
    ReceiverStateMachine.State state = stateMachine.state();
    if (closed
        || state == ReceiverStateMachine.State.STOPPED
        || state == ReceiverStateMachine.State.BACKING_OFF
        || state == ReceiverStateMachine.State.ERROR) {
      return;
    }
    metrics.record("receiver_recoverable_failure", Map.of("code", code));
    apply(stateMachine.reduce(event));
  }

  private void fatal(ReceiverStateMachine.FatalError error, String code) {
    if (closed || stateMachine.state() == ReceiverStateMachine.State.STOPPED) {
      return;
    }
    errorCode = code;
    metrics.record("receiver_fatal_error", Map.of("code", code));
    apply(stateMachine.reduce(ReceiverStateMachine.Event.fatal(error)));
  }

  private void cleanupConnection() {
    generation++;
    cancel(expiryTimer);
    cancel(retryTimer);
    cancel(statsTimer);
    expiryTimer = null;
    retryTimer = null;
    statsTimer = null;
    if (session != null) {
      session.close();
      session = null;
    }
    if (markerProbe != null) {
      markerProbe.close();
      markerProbe = null;
    }
    if (signaling != null) {
      signaling.close();
      signaling = null;
    }
    pendingRemoteIce.clear();
    remoteDescriptionReady = false;
    automation.clear();
    pairingCode = null;
    sessionId = null;
    latestStats = null;
    metrics.record("receiver_connection_cleaned");
  }

  private void post(int callbackGeneration, Runnable callback) {
    if (closed || executor.isShutdown()) {
      return;
    }
    try {
      executor.execute(() -> {
        if (!closed && callbackGeneration == generation) {
          callback.run();
        }
      });
    } catch (RejectedExecutionException ignored) {
      // App shutdown raced the callback; the callback belongs to disposed ownership.
    }
  }

  private boolean send(SignalingMessage message) {
    if (signaling == null) {
      return false;
    }
    try {
      signaling.send(message);
      return true;
    } catch (RuntimeException error) {
      recover("signaling_send_failed");
      return false;
    }
  }

  private void publish() {
    Presentation presentation = new Presentation(
        stateMachine.state(), pairingCode, errorCode, latestStats);
    mainHandler.post(() -> observer.onPresentation(presentation));
  }

  private static long elapsedMs(long startNs) {
    if (startNs <= 0L) {
      return 0L;
    }
    return TimeUnit.NANOSECONDS.toMillis(SystemClock.elapsedRealtimeNanos() - startNs);
  }

  private static String nextMessageId() {
    return UUID.randomUUID().toString();
  }

  private static void put(Map<String, Object> fields, String key, Object value) {
    if (value != null) {
      fields.put(key, value);
    }
  }

  private static void cancel(ScheduledFuture<?> future) {
    if (future != null) {
      future.cancel(false);
    }
  }

  @Override
  public void close() {
    if (!closeRequested.compareAndSet(false, true)) {
      return;
    }
    executor.execute(() -> {
      closed = true;
      apply(stateMachine.reduce(ReceiverStateMachine.Event.stop()));
      runtime.close();
      metrics.record("receiver_runtime_closed");
      metrics.close();
    });
    executor.shutdown();
  }
}
