# macOS Sender 与 Android TV Receiver 调研记录

## 目标

在现有投屏项目中保留 macOS Sender、Go Signaling Service 和公网 coturn，新增
Android TV Receiver。Receiver 启动并注册后展示配对码，macOS GUI 或 CLI 输入配对码
后发送主屏复制或 1920×1080 虚拟扩展屏。

## 已确认的起点

- Go signaling protocol 已实现 Receiver 注册、8 位一次性配对码、Sender join、
  SDP/ICE 透明转发和断线清理。
- macOS 客户端已有 H.264 Sender、主屏复制、虚拟扩展屏、Direct UDP、强制
  TURN/UDP、RTCStats 和诊断导出；CLI 尚缺直接传入配对码的参数。
- M150 preview 已提供可由 App 直接消费的 arm64-v8a AAR，以及包含 Apple
  low-latency rate-control 支持的 macOS XCFramework；下游项目当前仍使用旧产物。
- 本机已安装 arm64 Android CLI/Emulator 工具链，但现有 AVD 是手机形态；SDK
  仓库可安装 API 31 Android TV arm64-v8a image，并已有 1080p TV device definition。
- 公网 coturn 已部署并有 UDP allocation 证据；公网 screencast signaling 尚未部署。

## 已确认的决策

### 一期验收环境

一期正式验收环境是单台 Mac 上的 1080p arm64 Android TV emulator 与 macOS
Sender。应用必须是 TV 形态并支持遥控器导航，但不把真实 TV 硬件、硬件 decoder
或真实 TV 性能作为一期门槛。

### Signaling 与媒体拓扑

一期启动本机 Go signaling server。macOS 使用 host loopback，Android Emulator
通过 emulator 的 host-loopback alias 访问同一服务；不部署或验收公网 signaling。

Direct UDP 只作为开发对照。生产路径仍设置 relay-only，只配置现有公网 coturn 的
TURN/UDP endpoint，并由 selected ICE candidate 证明确实经过 relay。Signaling
是否使用 WS/WSS 不改变媒体路径，一期允许 plain WS。

### Android reference runtime configuration

Android TV 端采用一个集中、显式的 `ReferenceRuntimeConfig.java` 作为 reference
implementation 的配置入口。它直接表达 signaling、ICE profile、TURN/UDP 和
CastTuning 默认值，不增加设置页、ADB provisioning、持久化配置、依赖注入或远程
配置服务。该选择优先降低下游 Android 开发者阅读和复制样例的成本，不把样例包装成
生产配置框架。

Java 通过稳定的 `R.string.reference_*` 引用 Android resources。`main` source set
提交字段完整、可编译但凭据为占位值的 `reference_runtime.xml`；被 Git 忽略的
`debug` source set 同名 XML 保存真实固定 TURN credential，并在本机构建时覆盖
占位值。缺少本机 override 时 App 明确报告配置缺失，不发起注册。

真实值会进入本机 debug APK，这是 reference App 的已知边界；它们不进入 Git、
日志、metrics、诊断导出或 UI。现有 macOS 客户端的 machine-local runtime config
contract 暂不因此改变。

### Android TV Receiver 生命周期

Receiver 是常驻待投屏端。App 启动且配置有效时自动初始化 WebRTC、连接 signaling、
注册并展示配对码。配对码过期后自动建立新的 signaling connection 并注册新码；
Sender 停止、断线或会话失败后清理旧画面和 `PeerConnection`，再回到新的待配对状态。

`PeerConnection` 和配对码属于单次投屏会话；`PeerConnectionFactory` 与 EGL context
在 App 生命周期内复用。暂时性 signaling 故障使用有限退避自动重连；配置无效或
H.264 不可用等不可恢复错误才停在可手动重试的错误状态。Server 不增加 session
resume 或持久化 registry。

### Android TV 应用形态

Receiver 必须是符合 Android TV sample 与 TV app quality contract 的 TV-only
应用，而不是为手机 Activity 增加一个 TV launcher。至少包含：

- `android.software.leanback` TV feature、`LEANBACK_LAUNCHER`、横屏 Activity，
  并显式声明 touchscreen 等 TV 不保证具备的硬件不是必需项；
- 符合 TV launcher 要求的 app icon 与 320×180 banner；
- 面向 10-foot viewing distance 的字号、对比度、safe area 和简洁信息层级；
- 所有操作可由 D-pad 完成，焦点可见、顺序确定，Back/Home 与 Activity lifecycle
  遵循 TV 平台预期；
- 视频使用 `SurfaceViewRenderer`，不为常规视频引入 `TextureView` 或 Media3；
- 等待、播放、后台切换和 Activity 销毁时正确管理 screen-on、EGL、renderer、
  `PeerConnection` 与 signaling，不依赖触摸、camera 或 microphone permission。

一期 UI 只包含配对码/连接状态、全屏接收画面、轻量 metrics 与可恢复错误操作，
不把工程说明、协议字段或验收文字显示给终端用户。

UI 实现采用 Java 与 classic Android Views/XML，不使用 Kotlin + Compose for TV。
M150 AAR、`SurfaceViewRenderer`、signaling、PeerConnection、stats 和 runtime constants
因此保持在同一语言与直接 View 模型中。该选择不降低 Android TV 行为与视觉规范，
理由记录在 [ADR-0002](../adr/0002-use-java-views-for-android-tv-reference-receiver.md)。

### macOS CLI 语义

CLI mode 是现有 macOS `.app` executable 的非交互启动方式，不新增无窗口 command-line
target 或后台 daemon。参数完整时 App 自动开始 Sender 会话，同时保留状态/metrics
窗口、Dock、Screen Recording permission identity 和统一 cleanup path。

新增 `--pairing-code <code>`，继续使用 `--role sender`、
`--source main|virtual`、`--profile`、`--config` 和可选 `--run-seconds`。
`--pairing-code` 与现有自动化使用的 `--pairing-code-file` 互斥；GUI 和 CLI 共享同一
`SessionCoordinator`、capture、WebRTC 与 observability 实现。

### H.264 与 M150 产物

下游同时切换到 preview release `0ff0e8c` 的 macOS XCFramework 与 Android AAR，
并以 release SHA-256 固定输入。CastTuning 配置迁移到 schema 2，Mac Sender 保持
Apple low-latency rate control 为 follow-up（默认关闭）；一期显式请求 Constrained Baseline 以优先兼容
Android emulator。若 SDP 与实际 SPS profile 不一致，沿用已确认的
`WARN_AND_CONTINUE` policy，在两端结构化记录 expected/actual profile 与 decoder
结果，不静默忽略 profile compatibility adjustment。

Android Receiver 使用 CastTuning decoder factory 并请求
`MediaFormat.KEY_LOW_LATENCY`。设备或 emulator 拒绝该 key 时，使用 M150 AAR 已有的
单次无该 key 重建 fallback；实际 decoder implementation 与 fallback 必须进入证据。

### 一期自动化与证据

功能 E2E 覆盖 Direct UDP 与强制 TURN/UDP 下的主屏复制和虚拟扩展屏，共四个组合。
每个组合必须证明 receiver-first pairing、H.264-only negotiation、1920×1080 decode/
render、符合请求的 selected ICE path、双方 metrics 和正常 teardown；virtual display
还必须证明创建与移除。

数值基线只使用现有确定性 1920×1080 virtual-display chart。Direct 与 TURN/UDP
各运行三次，沿用 marker、静态画质样本、无性能/画质门槛和 VMAF 仅作 reference 的
策略。保存 source/capture/decoded PNG、Android renderer evidence、完整 TV UI 截图、
差异热图，以及 PSNR、SSIM、VMAF 结果。

macOS 与 Android emulator 不共享 monotonic clock。本机 Go server 增加只读 clock
calibration endpoint，两端启动时重复采样，选择最低 RTT 样本建立 local monotonic
到共同时间域的映射，并在每次报告中保留 offset、RTT 与 uncertainty。跨端主指标是
“Android Render 软件端到端延迟”，不得表述为 optical glass-to-glass latency。

Android App 将事件和每秒 sample 写入 app-private JSONL；本机自动化通过 `run-as`/
ADB 拉取，不增加 TV 端导出流程。记录 signaling 分阶段耗时、ICE/DTLS/PeerConnection
状态、selected candidate、inbound bitrate/fps/loss/jitter/QP、frames received/decoded/
dropped、NACK/PLI/FIR、decoder implementation、CastTuning snapshot、low-latency
request/fallback、render cadence/size/first-frame/last-frame 和稳定错误。TV UI 只显示
配对/连接状态、轻量 metrics 与可恢复操作，不展示完整诊断字段。
