package cn.aweffr.webrtcscreencast.tv.session;

import java.util.List;
import java.util.Objects;

/**
 * Owns receiver lifecycle policy without depending on Android, WebSocket, or WebRTC types.
 * Callers execute the returned commands serially and feed completion events back into this object.
 */
public final class ReceiverStateMachine {
  public enum State {
    STOPPED,
    CONNECTING,
    REGISTERING,
    WAITING_CODE,
    PAIRED,
    NEGOTIATING,
    PLAYING,
    BACKING_OFF,
    ERROR
  }

  public enum Command {
    CONNECT,
    REGISTER,
    CREATE_PEER,
    APPLY_OFFER,
    SEND_ANSWER,
    ADD_ICE,
    CLEANUP,
    SCHEDULE_RETRY,
    SHOW_ERROR
  }

  public enum FatalError {
    INVALID_CONFIG,
    H264_UNAVAILABLE
  }

  public record Transition(State state, List<Command> commands, long retryDelaySeconds) {
    private Transition(State state, long retryDelaySeconds, Command... commands) {
      this(state, List.of(commands), retryDelaySeconds);
    }
  }

  public static final class Event {
    private enum Type {
      START,
      CONNECTED,
      REGISTERED,
      PAIRED,
      OFFER_RECEIVED,
      ANSWER_READY,
      REMOTE_ICE,
      REMOTE_TRACK,
      RECOVERABLE_FAILURE,
      EXPIRED,
      HANGUP,
      RETRY_TIMER,
      FATAL,
      MANUAL_RETRY,
      STOP
    }

    private final Type type;
    private final FatalError fatalError;

    private Event(Type type, FatalError fatalError) {
      this.type = type;
      this.fatalError = fatalError;
    }

    private static Event of(Type type) {
      return new Event(type, null);
    }

    public static Event start() {
      return of(Type.START);
    }

    public static Event connected() {
      return of(Type.CONNECTED);
    }

    public static Event registered() {
      return of(Type.REGISTERED);
    }

    public static Event paired() {
      return of(Type.PAIRED);
    }

    public static Event offerReceived() {
      return of(Type.OFFER_RECEIVED);
    }

    public static Event answerReady() {
      return of(Type.ANSWER_READY);
    }

    public static Event remoteIce() {
      return of(Type.REMOTE_ICE);
    }

    public static Event remoteTrack() {
      return of(Type.REMOTE_TRACK);
    }

    public static Event recoverableFailure() {
      return of(Type.RECOVERABLE_FAILURE);
    }

    public static Event expired() {
      return of(Type.EXPIRED);
    }

    public static Event hangup() {
      return of(Type.HANGUP);
    }

    public static Event retryTimer() {
      return of(Type.RETRY_TIMER);
    }

    public static Event fatal(FatalError error) {
      return new Event(Type.FATAL, Objects.requireNonNull(error, "error"));
    }

    public static Event manualRetry() {
      return of(Type.MANUAL_RETRY);
    }

    public static Event stop() {
      return of(Type.STOP);
    }
  }

  private State state = State.STOPPED;
  private int consecutiveFailures;
  private FatalError fatalError;

  public State state() {
    return state;
  }

  public FatalError fatalError() {
    return fatalError;
  }

  public Transition reduce(Event event) {
    Objects.requireNonNull(event, "event");

    if (event.type == Event.Type.STOP) {
      if (state == State.STOPPED) {
        return transition(State.STOPPED);
      }
      fatalError = null;
      consecutiveFailures = 0;
      return transition(State.STOPPED, Command.CLEANUP);
    }

    if (event.type == Event.Type.FATAL && state != State.STOPPED) {
      fatalError = event.fatalError;
      return transition(State.ERROR, Command.CLEANUP, Command.SHOW_ERROR);
    }

    if (event.type == Event.Type.RECOVERABLE_FAILURE
        || event.type == Event.Type.EXPIRED
        || event.type == Event.Type.HANGUP) {
      requireActive(event);
      return backOff();
    }

    return switch (state) {
      case STOPPED -> switch (event.type) {
        case START -> transition(State.CONNECTING, Command.CONNECT);
        default -> illegal(event);
      };
      case CONNECTING -> switch (event.type) {
        case CONNECTED -> transition(State.REGISTERING, Command.REGISTER);
        default -> illegal(event);
      };
      case REGISTERING -> switch (event.type) {
        case REGISTERED -> {
          consecutiveFailures = 0;
          yield transition(State.WAITING_CODE);
        }
        default -> illegal(event);
      };
      case WAITING_CODE -> switch (event.type) {
        case PAIRED -> transition(State.PAIRED, Command.CREATE_PEER);
        default -> illegal(event);
      };
      case PAIRED -> switch (event.type) {
        case OFFER_RECEIVED -> transition(State.NEGOTIATING, Command.APPLY_OFFER);
        default -> illegal(event);
      };
      case NEGOTIATING -> switch (event.type) {
        case ANSWER_READY -> transition(State.NEGOTIATING, Command.SEND_ANSWER);
        case REMOTE_ICE -> transition(State.NEGOTIATING, Command.ADD_ICE);
        case REMOTE_TRACK -> transition(State.PLAYING);
        default -> illegal(event);
      };
      case PLAYING -> switch (event.type) {
        case REMOTE_ICE -> transition(State.PLAYING, Command.ADD_ICE);
        default -> illegal(event);
      };
      case BACKING_OFF -> switch (event.type) {
        case RETRY_TIMER -> transition(State.CONNECTING, Command.CONNECT);
        default -> illegal(event);
      };
      case ERROR -> switch (event.type) {
        case MANUAL_RETRY -> {
          fatalError = null;
          consecutiveFailures = 0;
          yield transition(State.CONNECTING, Command.CLEANUP, Command.CONNECT);
        }
        default -> illegal(event);
      };
    };
  }

  private Transition backOff() {
    long delaySeconds = 1L << Math.min(consecutiveFailures, 3);
    consecutiveFailures++;
    state = State.BACKING_OFF;
    return new Transition(
        state, delaySeconds, Command.CLEANUP, Command.SCHEDULE_RETRY);
  }

  private void requireActive(Event event) {
    if (state == State.STOPPED || state == State.ERROR || state == State.BACKING_OFF) {
      throw new IllegalStateException("Event " + event.type + " is invalid in state " + state);
    }
  }

  private Transition transition(State next, Command... commands) {
    state = next;
    return new Transition(state, -1L, commands);
  }

  private Transition illegal(Event event) {
    throw new IllegalStateException("Event " + event.type + " is invalid in state " + state);
  }
}
