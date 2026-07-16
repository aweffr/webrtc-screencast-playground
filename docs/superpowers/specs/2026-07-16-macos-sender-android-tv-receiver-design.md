# macOS Sender 与 Android TV Receiver 一期设计

## 目标

在现有 macOS 投屏闭环中新增一个 Android TV-only Receiver reference app。Receiver
启动后自动连接本机 Go Signaling Service、注册并展示一次性配对码；用户在 macOS
Sender GUI 输入配对码，或用同一 `.app` executable 的 CLI 直接传入配对码，即可把
主屏复制或 app 创建的 1920×1080 虚拟扩展屏以 H.264 投到 Android TV。

一期正式验收环境是同一台 Apple Silicon Mac 上的 macOS Sender 与 1080p arm64
Android TV API 31 emulator。功能验收覆盖 Direct UDP 与强制公网 TURN/UDP 两种
ICE profile、两种画面来源；量化基线只使用确定性的虚拟扩展屏。结果以真实连接、
selected path、双方 metrics、Android renderer 画面证据和可复跑报告为准，不设置
画质或延迟门槛，也不声称 optical glass-to-glass latency。

## 既有边界与依赖

- Go server 已实现 receiver-first pairing、8 位 Crockford code、SDP/ICE 透明转发、
  会话清理和 Prometheus metrics。
- macOS app 已实现 H.264 Sender/Receiver、ScreenCaptureKit、主屏与虚拟屏、两种
  ICE profile、RTCStats、JSONL 诊断和单 Mac 自动化媒体基线。
- `my-webrtc-builds` preview release
  `webrtc-m150.7871.3-0ff0e8c-20260714-macos-android-preview.1` 提供经过真实验证的
  universal macOS XCFramework 与 arm64-v8a AAR。AAR 包含 `classes.jar` 和
  `libjingle_peerconnection_so.so`；XCFramework 支持 opt-in Apple
  `EnableLowLatencyRateControl`。
- 公网 coturn 继续只提供 TURN/UDP 媒体中继。本机 signaling 使用 plain WS；
  emulator 通过 `10.0.2.2` 访问 host loopback。

## 已比较方案

### Android UI：Java + classic Views/XML（采用）

Java 直接消费 M150 AAR 的 Java API，`SurfaceViewRenderer` 直接位于 View hierarchy，
signaling、PeerConnection、stats 和 sample 配置都保持同一语言。该方案依赖少，方便
下游 Android 开发者复制关键路径，并仍然完整遵守 Android TV 的 Leanback、D-pad、
10-foot UI 与生命周期规范。

Kotlin + Compose for TV 是官方推荐的新 TV UI 路线，但本 reference app 只有待配对、
播放和错误三个简单界面。为它引入 Kotlin、Compose runtime、TV Material 和
`AndroidView` bridge 会增加与媒体闭环无关的理解成本，因此不采用。详细取舍见
[ADR-0002](../../adr/0002-use-java-views-for-android-tv-reference-receiver.md)。

### Android 会话组织：一个 app-lifetime runtime + 每次投屏一个 session（采用）

`ReceiverRuntime` 在 Activity 生命周期内持有 EGL、`PeerConnectionFactory` 和
CastTuning controller。`ReceiverSession` 只持有一次配对使用的 WebSocket、
PeerConnection、remote track、stats sampler 与配对码。配对码过期、Sender hangup、
连接失败或用户重试时销毁 session，再注册新码；不重建昂贵的 factory/EGL。

每次重连都重建全部 WebRTC runtime 虽然代码表面更直线，但会放大资源抖动并增加
EGL/MediaCodec cleanup 风险；永久复用一个 PeerConnection 又会把已消费配对码、
remote description 与 ICE generation 泄漏到下一次投屏，因此两者均不采用。

### 自动化 profile 切换：Android product flavor（采用）

App 提供 `directBaselineDebug` 与 `productionRelayDebug` 两个 reference build variant。
二者只覆盖非敏感的 `reference_ice_profile` resource；signaling、TURN endpoint 与真实
credential 仍来自同一个 ignored debug XML。这样自动化可以预构建两个 APK 并明确
证明 requested profile，不把 ADB extras 或隐藏设置页变成 runtime configuration
contract。

运行时通过 Intent/ADB 注入全部配置虽然便于脚本，但会与“一个 Java 配置入口 + XML
实际值”的已确认边界冲突。每轮重写 XML 再 rebuild 则把构建时间混入执行路径，也更
容易留下错误 profile，因此不采用。

### 跨端时钟：本机 signaling server 作为校准时间域（采用）

macOS 与 Android emulator 的 monotonic epoch 不相同，不能直接相减。Server 增加
只读 `GET /clock`，返回响应生成时的 Unix nanoseconds。两端用本地 monotonic 时间
包住多次请求，选择 RTT 最低样本，建立 `common_ns = local_monotonic_ns + offset_ns`
映射，并保存 RTT、offset、uncertainty 与样本数。离线分析只使用已校准时间。

在 marker 中写 wall clock 会把时钟格式与 marker codec 耦合，也无法消除两端 clock
offset；依赖 host/emulator 偶然相近的 wall clock 则无法量化误差，因此不采用。

## Repository 与构建输入

新增 Android Gradle project：

```text
apps/android-tv/
  settings.gradle.kts
  build.gradle.kts
  gradle/wrapper/
  gradlew
  app/build.gradle.kts
  app/src/main/AndroidManifest.xml
  app/src/main/java/cn/aweffr/webrtcscreencast/tv/
  app/src/main/res/
  app/src/debug/res/values/reference_runtime.local.xml  # ignored
```

`artifacts/SHA256SUMS` 固定 preview AAR 与 XCFramework zip 的 release SHA-256。
`scripts/bootstrap-webrtc.sh` 从明确的 preview release URL 获取缺失资产、校验后解压
XCFramework；Android Gradle module 直接消费已校验的本地 AAR，不复制或重新打包。
下载产物、Gradle cache、APK、metrics、截图和本机 credential 均不提交 Git。

Android 固定 JDK 17、Gradle 9.4.1、AGP 9.2.1、compile/target SDK 36、min SDK 26 和
`arm64-v8a`。一期 AVD 固定 `tv_1080p` device 与 API 31
`system-images;android-31;android-tv;arm64-v8a`，由脚本幂等创建，不修改已有手机 AVD。

## Android TV application contract

Manifest 声明 `android.software.leanback` required、touchscreen not required、
`LEANBACK_LAUNCHER`、landscape Activity、Internet permission、TV icon 和 320×180
banner。App 不声明 camera、microphone、recording 或 input-control permission。
由于一期使用 `ws://10.0.2.2`，network security config 只对 loopback/host alias
显式允许 cleartext，不作全局任意域放开。

单 Activity 使用三个互斥 presentation state：

1. `WAITING`：大号分组配对码、简短状态和轻量连接信息；
2. `PLAYING`：`SurfaceViewRenderer` 全屏显示 16:9 画面，safe-area overlay 只显示
   必要的 path/fps/bitrate；
3. `ERROR`：稳定的用户安全错误说明与 D-pad 可聚焦“重试”按钮。

所有交互可以仅用 D-pad 与 Back 完成，焦点状态明显；Home/后台停止会话并释放 renderer
surface，回前台重新注册。播放时保持屏幕常亮，等待和错误状态恢复系统默认。UI 不显示
SDP、candidate、TURN credential、验收说明、工程字段或 prompt 原文。

## Android runtime configuration

`ReferenceRuntimeConfig.java` 是唯一配置入口，读取稳定的 `R.string.reference_*`：

- signaling URL（emulator 默认 `ws://10.0.2.2:8080/ws`）；
- ICE profile；
- TURN/UDP URL、username、password；
- pairing/reconnect timeout；
- CastTuning schema 2 JSON。

`src/main/res/values/reference_runtime.xml` 提交完整字段和 `REPLACE_ME` credential。
本机 `src/debug/res/values/reference_runtime.local.xml` 覆盖真实值并被 Git 忽略。
production-relay variant 检测到 placeholder、空 credential、非 `turn:` URL 或非
`transport=udp` 时进入不可恢复的配置错误，既不连接 signaling 也不打印实际值；
direct variant 不要求 credential。配置 hash 只覆盖 canonical redacted fields。

CastTuning 使用 schema 2，显式请求 Constrained Baseline 和 Android decoder low
latency，并把 Apple low-latency rate control 保持为 `false`。Android 通过 `CastTuningController` 配置
field trials/RTCConfiguration、创建 `CastTuningVideoDecoderFactory` 并 attach receiver。
若 MediaCodec 拒绝 `KEY_LOW_LATENCY`，沿用 AAR 内置的一次无该 key 重试；app 记录
requested 与 decoder implementation，自动化从该进程 logcat 的稳定 WebRTC fallback
事件提取 fallback 结果；不复制第二套 decoder fallback。

## Signaling 与 Receiver 状态机

Android 使用 OkHttp WebSocket，JSON envelope 与现有 protocol v1 完全一致。解析器
只接受已知 version/type 和有界 payload；日志和 metrics 不保存配对码全文、SDP、ICE
candidate 或 credential。Receiver 状态机为：

```text
STOPPED
  → CONNECTING → REGISTERING → WAITING_CODE → PAIRED → NEGOTIATING → PLAYING
                  ↘ recoverable failure/expiry/hangup ↘
                    BACKING_OFF → CONNECTING
                  ↘ invalid config/H.264 unavailable
                    ERROR → manual retry
```

server 当前把 connection 绑定到一个 role；配对码过期后不能在同一 WebSocket 再次
register。因此 expiry、hangup 与 disconnect 都关闭旧 socket/PeerConnection，采用
有限指数退避（1s、2s、4s、最高 8s）建立新 connection。用户可见状态不把正常重注册
表现为 fatal error。Activity stop/destroy 的 cleanup 幂等并取消所有 timer/callback。

收到 `session.paired` 后 Receiver 创建 recv-only video transceiver，只保留 H.264
`packetization-mode=1` capability，再应用 remote offer、创建 answer、处理 trickle ICE。
没有 H.264、出现第二条 remote video track、requested relay path 不成立或只选中 TCP
时会话证据失败。SDP 期望 Baseline 但实际 SPS/decoder 表现为 High 时按已确认的
`WARN_AND_CONTINUE`：两端结构化记录 expected/actual，不静默忽略，也不阻断画面。

## macOS Sender 变更

macOS 同时切换到 preview XCFramework 与 schema 2 tuning config；保持显式 Constrained
Baseline，并把 Apple low-latency rate control 明确保留为默认关闭的 follow-up。`LaunchOptions` 新增
`--pairing-code <code>`，与 `--pairing-code-file` 互斥。参数完整时同一 App 自动开始
Sender 会话，仍保留 Dock、状态/metrics window、Screen Recording permission identity
和统一 cleanup；不新增 headless target 或 daemon。

GUI 与 CLI 继续共享 `SessionCoordinator`、capture、WebRTC、signaling 与 metrics。
CLI source 仍为 `--source main|virtual`，profile 为
`--profile direct-baseline|production-relay`，可用 `--run-seconds` 自动结束。

macOS 在每次 session 启动时调用 `/clock` 完成校准，并把 calibration event 写入
Sender JSONL。校准失败会阻断量化 baseline，但不阻断普通功能投屏；普通会话明确记录
calibration unavailable。

## Android observability 与画面证据

`ReceiverMetricsRecorder` 向 app-private files 目录写 append-only JSONL。每条 record
包含 schema、session/run ID、profile、redacted config hash、wall time、
`elapsedRealtimeNanos`、event 和 fields。自动化通过 `run-as`/ADB 拉取；App 不增加导出
页面。事件覆盖：

- WebSocket connect/register/code/paired 分阶段耗时；
- offer/answer apply、ICE gathering/connection、DTLS/PeerConnection state；
- selected candidate pair/type/protocol 与 profile verification；
- first/last remote frame、renderer input/render cadence、分辨率；
- inbound bitrate/fps/loss/jitter/QP、received/decoded/dropped、NACK/PLI/FIR；
- decoder implementation、CastTuning snapshot、low-latency requested；
- retry、expiry、hangup、cleanup 和稳定 error code。

正常播放把 remote `VideoTrack` attach 到 `SurfaceViewRenderer`。量化 baseline 额外使用
renderer frame listener 对 marker sequence 进行 CRC 校验，并保存同序列
`receiver-decoded-*.png`；这条较重的 readback 路径只在工程 baseline mode 启用。
完整 TV UI screenshot 由 ADB 截取，作为 TV UI 与实际播放的附加证据，不替代 decoded
frame PNG。

## 自动化与分析

新增 cross-platform runner，复用现有 Go server、Mac Sender、marker/chart、质量分析与
secret scanner，Android TV Receiver 取代第二个 Mac Receiver。

量化模式下 chart 由同一 `.app` executable 的内部 child-process mode 呈现，Sender 仍按
普通 display filter 采集 virtual display。这样 marker 是另一个进程真实提交到扩展屏的
内容，不依赖 WindowServer 是否把采集进程自己的 window 合成进 display stream。child
把 sequence、commit monotonic timestamp 和 source-reference 文件名写入 session-private
JSONL；Sender teardown 后导入这些事件。该内部模式不改变用户可见 GUI/CLI contract。

功能矩阵是：

```text
direct-baseline  × main
direct-baseline  × virtual
production-relay × main
production-relay × virtual
```

每组必须证明 receiver-first pairing、H.264-only negotiation、1920×1080 render、
requested selected path、双方 metrics、正常 teardown；virtual 两组还必须证明 display
创建和移除。production-relay 的两端 selected pair 都必须是 `relay/relay + UDP`；
direct-baseline 必须是非 relay 的 UDP。Main 只作功能闭环，不参与数值画质比较。

量化基线按 Direct 1、TURN 1、Direct 2、TURN 2、Direct 3、TURN 3 交替执行，每次新建
Mac Sender、Android Receiver session、PeerConnection 和 virtual display。沿用 10 秒
warm-up、60 秒 measurement、500ms marker、三个 image triplet。离线分析先应用两端
clock calibration，再按 marker sequence 计算：

- Marker Commit-to-Capture Latency；
- Capture-to-Android Render Latency；
- Android Render Software End-to-End Latency（主指标）。

报告保留 calibration offset/RTT/uncertainty、signaling 与 WebRTC 建连耗时、marker
validity、p50/p95/max、source/capture/decoded PNG、heatmap、PSNR、SSIM 和 VMAF reference
列。VMAF 对静态图不作 pass/fail；所有延迟和画质结果只记录数据，不设置阈值。

raw evidence 位于 ignored `artifacts/android-tv-e2e/<run-id>/`，versioned aggregate 位于
`baselines/`。完整 retained tree 必须通过 configured-secret scan；报告不保留 local XML、
TURN credential、完整 pairing code、SDP 或 candidate string。

## 测试与验收

### 自动测试

- Go：`/clock` contract、cache/header、method、并发现有 signaling/race suite 无回归；
- Java unit：runtime config validation/redaction、protocol codec、state machine、retry、
  H.264 capability filter、RTCStats normalization、marker CRC 与 clock calibration；
- Android instrumentation/smoke：TV Activity 启动、Leanback intent、D-pad focus、配置错误、
  renderer lifecycle、AAR JNI load；
- Swift：direct pairing code/互斥参数、clock calibration、schema 2 config load；
- scripts：AVD provisioning、ADB artifact pull、cross-clock correlation、matrix/aggregate 与
  secret-scan failure path；
- build/lint：Go race tests、Gradle unit/lint/assemble、Xcode test/build、manifest/APK inspection。

### 真实单机 E2E

先运行四组功能矩阵，再运行六轮 virtual quantitative baseline。验收证据必须来自 exact
preview AAR/XCFramework SHA，Android TV API 31 arm64 emulator 与真实公网 coturn。
每轮进程返回、selected path、1920×1080 frame、JSONL、截图、PNG、分析和 cleanup 都
必须可审计；任一性能数值本身不导致失败。

## 明确不在一期

- 真实 Android TV 硬件、硬件 decoder 性能门槛或光学 scan-out 测量；
- 公网 signaling、强制 HTTPS/WSS、TURN/TCP、LAN production direct；
- 内容 corpus、流畅度门槛、动态视频或输入控制；
- 设置页、远程配置、credential provisioning、账号/身份或 persistent session；
- App Store / Play Store 发布、手机/平板适配、后台常驻 service；
- 画质、延迟、valid ratio 或 VMAF 的 pass/fail threshold。

## Follow-ups

- 在真实 Android TV 硬件补 MediaCodec implementation、`KEY_LOW_LATENCY` 接受情况、
  display compositor 与光学 glass-to-glass latency。
- 根据首批跨端数据再决定回归 budget、内容 corpus 和 cadence 优化。
- 将 signaling 部署到公网并补 WSS/服务认证，只在后续生产集成需求明确时进行。
- 全局键鼠与 Accessibility/Input Monitoring 权限保持独立事项，不进入投屏闭环。
