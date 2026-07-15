package cn.aweffr.webrtcscreencast.tv.session;

import org.webrtc.EglBase;
import org.webrtc.VideoSink;

/** Narrow lifecycle boundary consumed by the TV Activity and its UI tests. */
public interface ReceiverSessionController extends AutoCloseable {
  EglBase.Context eglContext();

  void start(VideoSink renderer, boolean baselineMode);

  void stop();

  void retry();

  @Override
  void close();
}
