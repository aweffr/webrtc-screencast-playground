package cn.aweffr.webrtcscreencast.tv.ui;

import static androidx.test.espresso.Espresso.onView;
import static androidx.test.espresso.Espresso.pressBackUnconditionally;
import static androidx.test.espresso.action.ViewActions.pressKey;
import static androidx.test.espresso.assertion.ViewAssertions.matches;
import static androidx.test.espresso.matcher.ViewMatchers.isDisplayed;
import static androidx.test.espresso.matcher.ViewMatchers.isFocusable;
import static androidx.test.espresso.matcher.ViewMatchers.withId;
import static androidx.test.espresso.matcher.ViewMatchers.withText;
import static org.hamcrest.Matchers.not;
import static org.junit.Assert.assertEquals;
import static org.junit.Assert.assertTrue;

import android.content.Intent;
import android.content.pm.ResolveInfo;
import android.view.WindowManager;
import android.view.KeyEvent;
import androidx.test.core.app.ActivityScenario;
import androidx.test.core.app.ApplicationProvider;
import androidx.test.ext.junit.runners.AndroidJUnit4;
import androidx.test.platform.app.InstrumentationRegistry;
import cn.aweffr.webrtcscreencast.tv.R;
import cn.aweffr.webrtcscreencast.tv.observability.RtcStatsNormalizer;
import cn.aweffr.webrtcscreencast.tv.session.ReceiverController;
import cn.aweffr.webrtcscreencast.tv.session.ReceiverSessionController;
import cn.aweffr.webrtcscreencast.tv.session.ReceiverStateMachine;
import java.util.concurrent.atomic.AtomicInteger;
import org.junit.After;
import org.junit.Before;
import org.junit.Test;
import org.junit.runner.RunWith;
import org.json.JSONObject;
import org.webrtc.EglBase;
import org.webrtc.VideoSink;

@RunWith(AndroidJUnit4.class)
public final class ReceiverActivityTest {
  private FakeController fake;

  @Before
  public void installFakeController() {
    fake = new FakeController();
    ReceiverActivity.setControllerFactoryForTest((context, config, observer) -> {
      fake.observer = observer;
      return fake;
    });
  }

  @After
  public void resetFactory() {
    ReceiverActivity.resetControllerFactoryForTest();
  }

  @Test
  public void manifestIsTvOnlyLeanbackAndLandscape() throws Exception {
    Intent intent = new Intent(Intent.ACTION_MAIN)
        .addCategory(Intent.CATEGORY_LEANBACK_LAUNCHER)
        .setPackage(ApplicationProvider.getApplicationContext().getPackageName());
    ResolveInfo resolved = ApplicationProvider.getApplicationContext()
        .getPackageManager()
        .resolveActivity(intent, 0);

    assertTrue(resolved != null);
    assertEquals(
        android.content.pm.ActivityInfo.SCREEN_ORIENTATION_LANDSCAPE,
        resolved.activityInfo.screenOrientation);
  }

  @Test
  public void compiledReferenceRuntimeJsonRemainsValid() throws Exception {
    String encoded = ApplicationProvider.getApplicationContext()
        .getString(R.string.reference_cast_tuning_json);

    assertEquals(3, new JSONObject(encoded).getInt("schema_version"));
  }

  @Test
  public void waitingPlayingAndErrorRemainDpadOperable() {
    try (ActivityScenario<ReceiverActivity> scenario =
             ActivityScenario.launch(ReceiverActivity.class)) {
      fake.emit(new ReceiverController.Presentation(
          ReceiverStateMachine.State.WAITING_CODE, "AB12CD34", null, null));
      onView(withId(R.id.pairing_code)).check(matches(withText("AB12 CD34")));
      onView(withId(R.id.waiting_panel)).check(matches(isDisplayed()));
      onView(withId(R.id.video_renderer)).check(matches(not(isDisplayed())));

      fake.emit(new ReceiverController.Presentation(
          ReceiverStateMachine.State.PLAYING, null, null, (RtcStatsNormalizer.Sample) null));
      onView(withId(R.id.video_renderer)).check(matches(isDisplayed()));
      scenario.onActivity(activity -> assertTrue(
          (activity.getWindow().getAttributes().flags
              & WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON) != 0));

      fake.emit(new ReceiverController.Presentation(
          ReceiverStateMachine.State.ERROR, null, "test_error", null));
      onView(withId(R.id.retry_button))
          .check(matches(isDisplayed()))
          .check(matches(isFocusable()));
      scenario.onActivity(activity -> activity.findViewById(R.id.retry_button).requestFocus());
      onView(withId(R.id.retry_button)).perform(pressKey(KeyEvent.KEYCODE_DPAD_CENTER));
      assertEquals(1, fake.retryCount.get());
    }
    assertTrue(fake.stopCount.get() > 0);
    assertEquals(1, fake.closeCount.get());
  }

  @Test
  public void systemBackStopsAndClosesTheReceiver() {
    try (ActivityScenario<ReceiverActivity> ignored =
             ActivityScenario.launch(ReceiverActivity.class)) {
      pressBackUnconditionally();
      InstrumentationRegistry.getInstrumentation().waitForIdleSync();
    }

    assertTrue(fake.stopCount.get() > 0);
    assertEquals(1, fake.closeCount.get());
  }

  private static final class FakeController implements ReceiverSessionController {
    private ReceiverController.Observer observer;
    private final AtomicInteger retryCount = new AtomicInteger();
    private final AtomicInteger stopCount = new AtomicInteger();
    private final AtomicInteger closeCount = new AtomicInteger();

    void emit(ReceiverController.Presentation presentation) {
      InstrumentationRegistry.getInstrumentation().runOnMainSync(
          () -> observer.onPresentation(presentation));
    }

    @Override
    public EglBase.Context eglContext() {
      return null;
    }

    @Override
    public void start(VideoSink renderer, boolean baselineMode) {}

    @Override
    public void stop() {
      stopCount.incrementAndGet();
    }

    @Override
    public void retry() {
      retryCount.incrementAndGet();
    }

    @Override
    public void close() {
      closeCount.incrementAndGet();
    }
  }
}
