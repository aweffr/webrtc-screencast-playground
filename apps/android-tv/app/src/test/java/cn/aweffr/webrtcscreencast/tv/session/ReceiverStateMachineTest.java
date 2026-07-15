package cn.aweffr.webrtcscreencast.tv.session;

import static cn.aweffr.webrtcscreencast.tv.session.ReceiverStateMachine.Command.ADD_ICE;
import static cn.aweffr.webrtcscreencast.tv.session.ReceiverStateMachine.Command.APPLY_OFFER;
import static cn.aweffr.webrtcscreencast.tv.session.ReceiverStateMachine.Command.CLEANUP;
import static cn.aweffr.webrtcscreencast.tv.session.ReceiverStateMachine.Command.CONNECT;
import static cn.aweffr.webrtcscreencast.tv.session.ReceiverStateMachine.Command.CREATE_PEER;
import static cn.aweffr.webrtcscreencast.tv.session.ReceiverStateMachine.Command.REGISTER;
import static cn.aweffr.webrtcscreencast.tv.session.ReceiverStateMachine.Command.SCHEDULE_RETRY;
import static cn.aweffr.webrtcscreencast.tv.session.ReceiverStateMachine.Command.SEND_ANSWER;
import static cn.aweffr.webrtcscreencast.tv.session.ReceiverStateMachine.Command.SHOW_ERROR;
import static org.junit.Assert.assertEquals;
import static org.junit.Assert.assertThrows;

import java.util.List;
import org.junit.Test;

public final class ReceiverStateMachineTest {
  @Test
  public void happyPathCreatesOnePeerAndNegotiatesBeforePlaying() {
    ReceiverStateMachine machine = new ReceiverStateMachine();

    assertTransition(machine.reduce(ReceiverStateMachine.Event.start()),
        ReceiverStateMachine.State.CONNECTING, CONNECT);
    assertTransition(machine.reduce(ReceiverStateMachine.Event.connected()),
        ReceiverStateMachine.State.REGISTERING, REGISTER);
    assertTransition(machine.reduce(ReceiverStateMachine.Event.registered()),
        ReceiverStateMachine.State.WAITING_CODE);
    assertTransition(machine.reduce(ReceiverStateMachine.Event.paired()),
        ReceiverStateMachine.State.PAIRED, CREATE_PEER);
    assertTransition(machine.reduce(ReceiverStateMachine.Event.offerReceived()),
        ReceiverStateMachine.State.NEGOTIATING, APPLY_OFFER);
    assertTransition(machine.reduce(ReceiverStateMachine.Event.answerReady()),
        ReceiverStateMachine.State.NEGOTIATING, SEND_ANSWER);
    assertTransition(machine.reduce(ReceiverStateMachine.Event.remoteIce()),
        ReceiverStateMachine.State.NEGOTIATING, ADD_ICE);
    assertTransition(machine.reduce(ReceiverStateMachine.Event.remoteTrack()),
        ReceiverStateMachine.State.PLAYING);
    assertTransition(machine.reduce(ReceiverStateMachine.Event.remoteIce()),
        ReceiverStateMachine.State.PLAYING, ADD_ICE);
  }

  @Test
  public void expiryAndHangupCleanUpOneTimeSessionBeforeFreshRegistration() {
    ReceiverStateMachine waiting = machineIn(ReceiverStateMachine.State.WAITING_CODE);
    ReceiverStateMachine.Transition expired = waiting.reduce(ReceiverStateMachine.Event.expired());

    assertTransition(expired, ReceiverStateMachine.State.BACKING_OFF, CLEANUP, SCHEDULE_RETRY);
    assertEquals(1L, expired.retryDelaySeconds());
    assertTransition(waiting.reduce(ReceiverStateMachine.Event.retryTimer()),
        ReceiverStateMachine.State.CONNECTING, CONNECT);

    ReceiverStateMachine playing = machineIn(ReceiverStateMachine.State.PLAYING);
    ReceiverStateMachine.Transition hungUp = playing.reduce(ReceiverStateMachine.Event.hangup());
    assertTransition(hungUp, ReceiverStateMachine.State.BACKING_OFF, CLEANUP, SCHEDULE_RETRY);
  }

  @Test
  public void recoverableFailuresUseBoundedExponentialBackoff() {
    ReceiverStateMachine machine = new ReceiverStateMachine();
    machine.reduce(ReceiverStateMachine.Event.start());

    long[] expected = {1L, 2L, 4L, 8L, 8L};
    for (long delay : expected) {
      ReceiverStateMachine.Transition failed =
          machine.reduce(ReceiverStateMachine.Event.recoverableFailure());
      assertTransition(failed, ReceiverStateMachine.State.BACKING_OFF, CLEANUP, SCHEDULE_RETRY);
      assertEquals(delay, failed.retryDelaySeconds());
      machine.reduce(ReceiverStateMachine.Event.retryTimer());
    }

    machine.reduce(ReceiverStateMachine.Event.connected());
    machine.reduce(ReceiverStateMachine.Event.registered());
    ReceiverStateMachine.Transition afterRegistration =
        machine.reduce(ReceiverStateMachine.Event.recoverableFailure());
    assertEquals(1L, afterRegistration.retryDelaySeconds());
  }

  @Test
  public void invalidConfigAndMissingH264AreFatalUntilManualRetry() {
    for (ReceiverStateMachine.FatalError error : List.of(
        ReceiverStateMachine.FatalError.INVALID_CONFIG,
        ReceiverStateMachine.FatalError.H264_UNAVAILABLE)) {
      ReceiverStateMachine machine = new ReceiverStateMachine();
      machine.reduce(ReceiverStateMachine.Event.start());

      assertTransition(machine.reduce(ReceiverStateMachine.Event.fatal(error)),
          ReceiverStateMachine.State.ERROR, CLEANUP, SHOW_ERROR);
      assertTransition(machine.reduce(ReceiverStateMachine.Event.manualRetry()),
          ReceiverStateMachine.State.CONNECTING, CLEANUP, CONNECT);
    }
  }

  @Test
  public void stopIsIdempotentAndIllegalEventsAreRejected() {
    ReceiverStateMachine machine = new ReceiverStateMachine();
    assertTransition(machine.reduce(ReceiverStateMachine.Event.stop()),
        ReceiverStateMachine.State.STOPPED);
    assertTransition(machine.reduce(ReceiverStateMachine.Event.stop()),
        ReceiverStateMachine.State.STOPPED);

    assertThrows(IllegalStateException.class,
        () -> machine.reduce(ReceiverStateMachine.Event.offerReceived()));

    machine.reduce(ReceiverStateMachine.Event.start());
    assertTransition(machine.reduce(ReceiverStateMachine.Event.stop()),
        ReceiverStateMachine.State.STOPPED, CLEANUP);
  }

  private static ReceiverStateMachine machineIn(ReceiverStateMachine.State target) {
    ReceiverStateMachine machine = new ReceiverStateMachine();
    machine.reduce(ReceiverStateMachine.Event.start());
    if (target == ReceiverStateMachine.State.CONNECTING) {
      return machine;
    }
    machine.reduce(ReceiverStateMachine.Event.connected());
    machine.reduce(ReceiverStateMachine.Event.registered());
    if (target == ReceiverStateMachine.State.WAITING_CODE) {
      return machine;
    }
    machine.reduce(ReceiverStateMachine.Event.paired());
    machine.reduce(ReceiverStateMachine.Event.offerReceived());
    machine.reduce(ReceiverStateMachine.Event.remoteTrack());
    if (target == ReceiverStateMachine.State.PLAYING) {
      return machine;
    }
    throw new IllegalArgumentException("Unsupported target state: " + target);
  }

  private static void assertTransition(
      ReceiverStateMachine.Transition transition,
      ReceiverStateMachine.State state,
      ReceiverStateMachine.Command... commands) {
    assertEquals(state, transition.state());
    assertEquals(List.of(commands), transition.commands());
  }
}
