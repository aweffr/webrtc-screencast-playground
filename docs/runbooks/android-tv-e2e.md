# macOS Sender → Android TV Receiver E2E

本 runbook 只覆盖一期正式环境：一台 Apple Silicon Mac，以及本机
`WebRTCScreencast_TV_API_31` Android TV arm64-v8a 1080p emulator。生产路径强制
TURN/UDP；Direct UDP 只作为对比基线。

## 前置条件

- Xcode、XcodeGen、Go、Android CLI/SDK/emulator、ADB、FFmpeg/libvmaf；
- Gradle/AGP 使用 JDK 17 runtime；M150 AAR 自身是 Java 8 classfile contract；
- macOS 已授予构建出的 `WebRTCScreencast.app` Screen Recording 权限；
- ignored runtime JSON 含公网 coturn 的 `turn:...?transport=udp`、username、password；
- Mac 已唤醒、解锁，且没有遗留的 managed virtual display。

```bash
cd /path/to/webrtc-screencast-playground
./scripts/check-virtual-display-state.py --expect 0
```

若检查器发现 `WebRTC Screencast Extended Display` 或 removal companion，而 owning process
已经退出，必须注销并重新登录 macOS 用户会话或重启；新进程无法释放旧进程遗留的
private `CGVirtualDisplay`。

## 单次功能闭环

Direct/main：

```bash
JAVA_HOME=$(/usr/libexec/java_home -v 17) \
./scripts/run-android-tv-e2e.sh \
  --profile direct-baseline \
  --source main \
  --run-seconds 20
```

TURN/UDP/virtual：

```bash
JAVA_HOME=$(/usr/libexec/java_home -v 17) \
./scripts/run-android-tv-e2e.sh \
  --profile production-relay \
  --source virtual \
  --runtime-config /absolute/path/to/ignored-runtime.json \
  --run-seconds 20
```

Runner 会依次完成：启动本地 Go signaling、安装匹配 flavor、先启动 TV Receiver 并读取
app-private 投屏码、启动同一 macOS `.app` 的 CLI Sender、校验 H.264 1920×1080 media 与
selected ICE path、保存双方 metrics/TV screenshot、停止 Sender、验证 TV 自动注册新码，
最后扫描 pairing code 和配置中的实际 TURN credential。

## 自动化画质与延迟

单次量化 run：

```bash
JAVA_HOME=$(/usr/libexec/java_home -v 17) \
./scripts/run-android-tv-e2e.sh \
  --profile production-relay \
  --source virtual \
  --runtime-config /absolute/path/to/ignored-runtime.json \
  --run-seconds 80 \
  --media-baseline
```

正式矩阵与三组交替 Direct/TURN baseline：

```bash
./scripts/run-android-tv-baseline.sh \
  --skip-macos-build \
  --runtime-config /absolute/path/to/ignored-runtime.json
```

`--dry-run` 可在不读取配置、不启动 emulator 的情况下检查执行顺序。量化模式用 10 秒
warm-up、60 秒 measurement、500ms marker 和三个 1920×1080 image triplet。chart 由同一
`.app` executable 的内部 child process 显示，Sender 仍走普通 ScreenCaptureKit display
capture；因此测量没有绕过屏幕采集边界。

`--skip-macos-build` 用于复用已取得 Screen Recording 授权的 `DerivedData` app；若代码有
变更，应先 build，再在 System Settings 中确认该 app 的授权，并完成所需的 logout/login，
最后才用该参数运行正式矩阵。runner 仍会检查 app executable 是否存在。

静态 QP 实验同样支持 `--skip-macos-build`。在第一次实验前完成一次 build、签名和授权，
然后让四组 QP case 全部复用同一个 `.app`，避免 ad-hoc rebuild 改变 Screen Recording
permission identity：

```bash
./scripts/run-static-qp-experiment.sh \
  --runtime-config "$PWD/secrets/runtime.json" \
  --xcframework /absolute/path/to/WebRTC-m150-macos-arm64.xcframework.zip \
  --skip-macos-build
```

报告分别列出：

- Marker Commit → Capture；
- Capture → Android render；
- Android render software end-to-end；
- Receiver/Sender WebSocket、投屏码签发、signaling ready、WebRTC negotiation → media；
- source/capture/Android render 的 PSNR、SSIM、VMAF reference 与 heatmap。

这些是校准后的 software marker 数据，不是 optical glass-to-glass；一期只记录，不设置
延迟或画质门槛。`showsCursor` 始终为 `true`。

## 证据与排障

Raw evidence 保存在 ignored `artifacts/android-tv-e2e/`；正式聚合报告保存在
`baselines/*-android-tv.{json,md}`。关键文件包括：

- `macos/*-sender/metrics.jsonl`：capture、sender media boundary、H.264、RTCStats、path；
- `android/receiver.jsonl`：signaling、render marker、decoder、RTCStats、path；
- `android/receiver-waiting.png`、`android/receiver-playing.png`；
- `source-reference-*`、`sender-capture-*`、`android-decoded-seq-*`、heatmap、VMAF JSON；
- `signaling-metrics.txt`、redacted logcat 和 host/run context。

`capture.callback_frames > 0` 但 outbound frames 为 0 时，先检查 sender media boundary 的
pixel format、VideoToolbox session/error 和 negotiated H.264 level。当前 1080p contract
使用 NV12 full-range (`420f`)；Android answer 会显式把选中的 packetization-mode=1 H.264
fmtp normalization 到 level 4.1，并记录日志，避免 M150 Android capability 仅声明 level
3.1 时造成 VideoToolbox `kVTParameterErr`。
