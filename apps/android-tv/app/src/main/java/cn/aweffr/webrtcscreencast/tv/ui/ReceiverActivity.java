package cn.aweffr.webrtcscreencast.tv.ui;

import android.app.Activity;
import android.annotation.SuppressLint;
import android.os.Build;
import android.os.Bundle;
import android.util.Log;
import android.view.View;
import android.view.WindowManager;
import android.widget.Button;
import android.widget.TextView;
import cn.aweffr.webrtcscreencast.tv.R;
import cn.aweffr.webrtcscreencast.tv.config.ReferenceRuntimeConfig;
import cn.aweffr.webrtcscreencast.tv.session.ReceiverController;
import cn.aweffr.webrtcscreencast.tv.session.ReceiverSessionController;
import cn.aweffr.webrtcscreencast.tv.session.ReceiverStateMachine;
import java.util.Locale;
import org.webrtc.EglBase;
import org.webrtc.RendererCommon;
import org.webrtc.SurfaceViewRenderer;

/** TV-only receiver surface: pairing code, video, or a D-pad retry action. */
public final class ReceiverActivity extends Activity {
  private static final String TAG = "ReceiverActivity";
  static final String EXTRA_BASELINE_MODE = "baseline_mode";

  interface ControllerFactory {
    ReceiverSessionController create(
        ReceiverActivity activity,
        ReferenceRuntimeConfig config,
        ReceiverController.Observer observer) throws Exception;
  }

  private static final ControllerFactory DEFAULT_FACTORY =
      (activity, config, observer) -> new ReceiverController(activity, config, observer);
  private static volatile ControllerFactory controllerFactory = DEFAULT_FACTORY;

  private SurfaceViewRenderer renderer;
  private View waitingPanel;
  private View errorPanel;
  private TextView waitingStatus;
  private TextView pairingCode;
  private Button retryButton;
  private ReceiverSessionController controller;
  private boolean rendererInitialized;
  private boolean started;

  @Override
  protected void onCreate(Bundle savedInstanceState) {
    super.onCreate(savedInstanceState);
    setContentView(R.layout.activity_receiver);
    renderer = findViewById(R.id.video_renderer);
    waitingPanel = findViewById(R.id.waiting_panel);
    errorPanel = findViewById(R.id.error_panel);
    waitingStatus = findViewById(R.id.waiting_status);
    pairingCode = findViewById(R.id.pairing_code);
    retryButton = findViewById(R.id.retry_button);
    retryButton.setOnClickListener(ignored -> retry());
    if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
      getOnBackInvokedDispatcher().registerOnBackInvokedCallback(
          android.window.OnBackInvokedDispatcher.PRIORITY_DEFAULT,
          this::finishFromBack);
    }
    showConnecting();
    createController();
  }

  private void createController() {
    try {
      ReferenceRuntimeConfig config = ReferenceRuntimeConfig.load(getResources());
      controller = controllerFactory.create(this, config, this::render);
      EglBase.Context sharedContext = controller.eglContext();
      if (sharedContext != null) {
        renderer.init(sharedContext, null);
        rendererInitialized = true;
      }
      renderer.setMirror(false);
      renderer.setScalingType(RendererCommon.ScalingType.SCALE_ASPECT_FIT);
      renderer.setEnableHardwareScaler(true);
      if (started) {
        controller.start(renderer, isBaselineMode());
      }
    } catch (Exception error) {
      Log.e(TAG, "Receiver initialization failed: " + error.getClass().getSimpleName());
      if (controller != null) {
        controller.close();
        controller = null;
      }
      showError();
    }
  }

  private boolean isBaselineMode() {
    return getIntent().getBooleanExtra(EXTRA_BASELINE_MODE, false);
  }

  @Override
  protected void onStart() {
    super.onStart();
    started = true;
    if (controller != null) {
      controller.start(renderer, isBaselineMode());
    }
  }

  @Override
  protected void onStop() {
    started = false;
    if (controller != null) {
      controller.stop();
    }
    clearKeepScreenOn();
    super.onStop();
  }

  @Override
  protected void onDestroy() {
    if (controller != null) {
      controller.close();
      controller = null;
    }
    if (rendererInitialized) {
      renderer.release();
      rendererInitialized = false;
    }
    super.onDestroy();
  }

  @SuppressLint("GestureBackNavigation")
  @SuppressWarnings("deprecation")
  @Override
  public void onBackPressed() {
    finishFromBack();
  }

  private void finishFromBack() {
    if (controller != null) {
      controller.stop();
    }
    finish();
  }

  private void retry() {
    showConnecting();
    if (controller == null) {
      createController();
    } else {
      controller.retry();
    }
  }

  private void render(ReceiverController.Presentation presentation) {
    ReceiverStateMachine.State state = presentation.state();
    switch (state) {
      case WAITING_CODE -> showPairingCode(presentation.pairingCode());
      case PAIRED, NEGOTIATING -> showPairing();
      case PLAYING -> showPlaying();
      case ERROR -> showError();
      case STOPPED, CONNECTING, REGISTERING, BACKING_OFF -> showConnecting();
    }
  }

  private void showConnecting() {
    renderer.setVisibility(View.GONE);
    waitingPanel.setVisibility(View.VISIBLE);
    errorPanel.setVisibility(View.GONE);
    waitingStatus.setText(R.string.connecting);
    pairingCode.setVisibility(View.GONE);
    clearKeepScreenOn();
  }

  private void showPairingCode(String code) {
    renderer.setVisibility(View.GONE);
    waitingPanel.setVisibility(View.VISIBLE);
    errorPanel.setVisibility(View.GONE);
    waitingStatus.setText(R.string.enter_code);
    pairingCode.setText(formatPairingCode(code));
    pairingCode.setVisibility(View.VISIBLE);
    clearKeepScreenOn();
  }

  private void showPairing() {
    renderer.setVisibility(View.GONE);
    waitingPanel.setVisibility(View.VISIBLE);
    errorPanel.setVisibility(View.GONE);
    waitingStatus.setText(R.string.pairing);
    pairingCode.setVisibility(View.GONE);
    clearKeepScreenOn();
  }

  private void showPlaying() {
    waitingPanel.setVisibility(View.GONE);
    errorPanel.setVisibility(View.GONE);
    renderer.setVisibility(View.VISIBLE);
    getWindow().addFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON);
  }

  private void showError() {
    renderer.setVisibility(View.GONE);
    waitingPanel.setVisibility(View.GONE);
    errorPanel.setVisibility(View.VISIBLE);
    clearKeepScreenOn();
    retryButton.requestFocus();
  }

  private void clearKeepScreenOn() {
    getWindow().clearFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON);
  }

  static String formatPairingCode(String raw) {
    if (raw == null) {
      return "";
    }
    String normalized = raw
        .replace("-", "")
        .replace(" ", "")
        .toUpperCase(Locale.ROOT);
    if (normalized.length() != 8) {
      return normalized;
    }
    return normalized.substring(0, 4) + " " + normalized.substring(4);
  }

  static void setControllerFactoryForTest(ControllerFactory factory) {
    controllerFactory = factory;
  }

  static void resetControllerFactoryForTest() {
    controllerFactory = DEFAULT_FACTORY;
  }
}
