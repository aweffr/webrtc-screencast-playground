package cn.aweffr.webrtcscreencast.tv.session;

import cn.aweffr.webrtcscreencast.tv.config.ReferenceRuntimeConfig;
import cn.aweffr.webrtcscreencast.tv.config.ReferenceRuntimeConfig.IceProfile;
import java.util.Collections;
import java.util.List;
import java.util.Objects;
import java.util.concurrent.atomic.AtomicBoolean;
import org.webrtc.AddIceObserver;
import org.webrtc.DataChannel;
import org.webrtc.IceCandidate;
import org.webrtc.MediaConstraints;
import org.webrtc.MediaStream;
import org.webrtc.MediaStreamTrack;
import org.webrtc.PeerConnection;
import org.webrtc.RTCStatsCollectorCallback;
import org.webrtc.RtpReceiver;
import org.webrtc.RtpTransceiver;
import org.webrtc.SdpObserver;
import org.webrtc.SessionDescription;
import org.webrtc.VideoSink;
import org.webrtc.VideoTrack;

/** One receiver-first cast session with a single recv-only H.264 video transceiver. */
public final class WebRtcReceiverSession implements AutoCloseable {
  public interface Listener {
    void onLocalAnswer(String sdp);

    void onLocalIceCandidate(IceCandidate candidate);

    void onIceGatheringComplete();

    void onRemoteVideoTrack(VideoTrack track);

    void onConnectionState(PeerConnection.PeerConnectionState state);

    void onNegotiationStage(String stage);

    void onFailure(String code, String message);
  }

  private final ReceiverRuntime runtime;
  private final Listener listener;
  private final VideoSink renderer;
  private final VideoSink evidenceSink;
  private final PeerConnection peerConnection;
  private final AtomicBoolean closed = new AtomicBoolean();
  private VideoTrack remoteVideoTrack;

  public WebRtcReceiverSession(
      ReceiverRuntime runtime,
      ReferenceRuntimeConfig config,
      VideoSink renderer,
      VideoSink evidenceSink,
      Listener listener) {
    this.runtime = Objects.requireNonNull(runtime, "runtime");
    this.listener = Objects.requireNonNull(listener, "listener");
    this.renderer = Objects.requireNonNull(renderer, "renderer");
    this.evidenceSink = evidenceSink;
    PeerConnection.RTCConfiguration rtcConfig = createRtcConfiguration(config);
    peerConnection = runtime.peerConnectionFactory().createPeerConnection(
        rtcConfig, new PeerObserver());
    if (peerConnection == null) {
      throw new IllegalStateException("peer_connection_creation_failed");
    }
    RtpTransceiver transceiver = peerConnection.addTransceiver(
        MediaStreamTrack.MediaType.MEDIA_TYPE_VIDEO,
        new RtpTransceiver.RtpTransceiverInit(
            RtpTransceiver.RtpTransceiverDirection.RECV_ONLY));
    if (transceiver == null) {
      close();
      throw new IllegalStateException("recv_transceiver_creation_failed");
    }
    transceiver.setCodecPreferences(H264CodecPolicy.requireReceiverCodecs(
        runtime.peerConnectionFactory()
            .getRtpReceiverCapabilities(MediaStreamTrack.MediaType.MEDIA_TYPE_VIDEO)
            .codecs)).throwError();
  }

  private PeerConnection.RTCConfiguration createRtcConfiguration(
      ReferenceRuntimeConfig config) {
    Objects.requireNonNull(config, "config").validate();
    List<PeerConnection.IceServer> iceServers;
    if (config.iceProfile() == IceProfile.PRODUCTION_RELAY) {
      iceServers = List.of(PeerConnection.IceServer.builder(config.turnUrl())
          .setUsername(config.turnUsername())
          .setPassword(config.turnPassword())
          .createIceServer());
    } else {
      iceServers = Collections.emptyList();
    }
    PeerConnection.RTCConfiguration rtcConfig =
        new PeerConnection.RTCConfiguration(iceServers);
    runtime.tuningController().configurePeerConnection(rtcConfig);
    rtcConfig.sdpSemantics = PeerConnection.SdpSemantics.UNIFIED_PLAN;
    rtcConfig.bundlePolicy = PeerConnection.BundlePolicy.MAXBUNDLE;
    rtcConfig.tcpCandidatePolicy = PeerConnection.TcpCandidatePolicy.DISABLED;
    rtcConfig.iceTransportsType = config.iceProfile() == IceProfile.PRODUCTION_RELAY
        ? PeerConnection.IceTransportsType.RELAY
        : PeerConnection.IceTransportsType.ALL;
    return rtcConfig;
  }

  public void applyOffer(String sdp) {
    checkOpen();
    listener.onNegotiationStage("set_remote_offer_started");
    peerConnection.setRemoteDescription(new ChainedSdpObserver("set_remote_offer") {
      @Override
      public void onSetSuccess() {
        listener.onNegotiationStage("set_remote_offer_succeeded");
        peerConnection.createAnswer(new ChainedSdpObserver("create_answer") {
          @Override
          public void onCreateSuccess(SessionDescription answer) {
            listener.onNegotiationStage("create_answer_succeeded");
            final String normalizedSdp;
            try {
              normalizedSdp = H264AnswerPolicy.normalizeFor1080p(answer.description);
            } catch (IllegalArgumentException error) {
              listener.onFailure("answer_h264_level_failed", error.getMessage());
              return;
            }
            listener.onNegotiationStage("answer_h264_level_4_1_applied");
            SessionDescription normalizedAnswer = new SessionDescription(
                SessionDescription.Type.ANSWER, normalizedSdp);
            peerConnection.setLocalDescription(new ChainedSdpObserver("set_local_answer") {
              @Override
              public void onSetSuccess() {
                listener.onNegotiationStage("set_local_answer_succeeded");
                listener.onLocalAnswer(normalizedSdp);
              }
            }, normalizedAnswer);
          }
        }, new MediaConstraints());
      }
    }, new SessionDescription(SessionDescription.Type.OFFER, sdp));
  }

  public void addRemoteIceCandidate(String candidate, String mid, int line) {
    checkOpen();
    peerConnection.addIceCandidate(new IceCandidate(mid, line, candidate), new AddIceObserver() {
      @Override
      public void onAddSuccess() {}

      @Override
      public void onAddFailure(String error) {
        listener.onFailure("add_remote_ice_failed", error);
      }
    });
  }

  public void collectStats(RTCStatsCollectorCallback callback) {
    checkOpen();
    peerConnection.getStats(callback);
  }

  private void checkOpen() {
    if (closed.get()) {
      throw new IllegalStateException("Receiver session is closed");
    }
  }

  @Override
  public void close() {
    if (!closed.compareAndSet(false, true)) {
      return;
    }
    if (remoteVideoTrack != null) {
      remoteVideoTrack.removeSink(renderer);
      if (evidenceSink != null) {
        remoteVideoTrack.removeSink(evidenceSink);
      }
      remoteVideoTrack = null;
    }
    if (peerConnection != null) {
      peerConnection.close();
      peerConnection.dispose();
    }
  }

  private class PeerObserver implements PeerConnection.Observer {
    @Override
    public void onSignalingChange(PeerConnection.SignalingState state) {}

    @Override
    public void onIceConnectionChange(PeerConnection.IceConnectionState state) {}

    @Override
    public void onIceConnectionReceivingChange(boolean receiving) {}

    @Override
    public void onIceGatheringChange(PeerConnection.IceGatheringState state) {
      if (state == PeerConnection.IceGatheringState.COMPLETE) {
        listener.onIceGatheringComplete();
      }
    }

    @Override
    public void onIceCandidate(IceCandidate candidate) {
      listener.onLocalIceCandidate(candidate);
    }

    @Override
    public void onIceCandidatesRemoved(IceCandidate[] candidates) {}

    @Override
    public void onAddStream(MediaStream stream) {}

    @Override
    public void onRemoveStream(MediaStream stream) {}

    @Override
    public void onDataChannel(DataChannel channel) {}

    @Override
    public void onRenegotiationNeeded() {}

    @Override
    public void onConnectionChange(PeerConnection.PeerConnectionState state) {
      listener.onConnectionState(state);
    }

    @Override
    public synchronized void onTrack(RtpTransceiver transceiver) {
      RtpReceiver receiver = transceiver.getReceiver();
      MediaStreamTrack track = receiver.track();
      if (!(track instanceof VideoTrack videoTrack)) {
        return;
      }
      if (remoteVideoTrack != null && remoteVideoTrack != videoTrack) {
        listener.onFailure("second_video_track", "A second remote video track is not allowed");
        return;
      }
      if (remoteVideoTrack == null) {
        remoteVideoTrack = videoTrack;
        runtime.tuningController().attachReceiver(receiver);
        videoTrack.addSink(renderer);
        if (evidenceSink != null) {
          videoTrack.addSink(evidenceSink);
        }
        listener.onRemoteVideoTrack(videoTrack);
      }
    }
  }

  private class ChainedSdpObserver implements SdpObserver {
    private final String operation;

    ChainedSdpObserver(String operation) {
      this.operation = operation;
    }

    @Override
    public void onCreateSuccess(SessionDescription description) {}

    @Override
    public void onSetSuccess() {}

    @Override
    public void onCreateFailure(String error) {
      listener.onFailure(operation + "_failed", error);
    }

    @Override
    public void onSetFailure(String error) {
      listener.onFailure(operation + "_failed", error);
    }
  }
}
