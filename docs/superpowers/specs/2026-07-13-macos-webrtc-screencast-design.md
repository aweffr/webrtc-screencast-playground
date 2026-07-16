# macOS WebRTC 低延迟投屏一期设计

## 目标

在一台 Apple Silicon Mac 上完成一个可重复运行的 native 投屏闭环：启动同一 app 的两个独立 process，Receiver 先向 Go WebSocket signaling server 申请一次性配对码，Sender 输入配对码后采集主屏或 app 创建的 1920×1080 虚拟扩展屏，以 H.264 发送给 Receiver 播放。链路分别在开发用 `direct-baseline` 和生产用 `production-relay` profile 下运行，并持续导出足以判断 capture、encode、ICE path、network、decode 和 render 行为的 metrics。

一期的成功标准是两条真实 PeerConnection 路径闭合且证据完整，不是达到预设画质或延迟数字。当前只有一台 Mac，因此 direct path 只能作为实现对照；production path 必须通过 selected candidate 证明实际使用公网 coturn TURN/UDP。

## 已比较方案

### 方案 A：一个 native app、每个 process 一个角色、透明 signaling（采用）

同一 macOS app 在启动后选择 Sender 或 Receiver。单机验收启动两个 process，每个 process 只持有一个角色和一条 PeerConnection；Go server 只管理配对并透明转发 SDP、trickle ICE 和生命周期消息。ScreenCaptureKit 与 WebRTC Objective-C framework 直接连接，接收侧使用 Metal renderer。

该方案最接近未来双机生产拓扑，没有进程内 loopback media path，也不会复制两套 client code。缺点是本机主屏复制时要明确排除 Receiver process/window，避免递归画面；这个测试排除项必须进入 effective config 和日志。

### 方案 B：Sender 和 Receiver 分成两个 app target（不采用）

两个 target 可以简化单个界面的状态，但会复制配置、signaling、PeerConnection、metrics 和发布逻辑。两端本来就共享同一协议与调优能力，一期没有足够差异支撑两个产品边界。

### 方案 C：单进程内创建两个 PeerConnection 做 loopback（不采用）

这种方式最容易演示画面，却绕过了双 process 生命周期、真实 WebSocket 配对和部分网络故障路径。它会形成只为测试存在的 session model，不能证明未来双机链路，因此不作为验收实现。

### Capture alternative：libwebrtc desktop capturer（不采用）

完整 C++ package 包含 desktop capture 能力，但一期采用 ScreenCaptureKit。后者原生提供 macOS capture permission、dirty rect、NV12 IOSurface、运行时 filter 与 private virtual display 对应的 `SCDisplay`，更适合应用层 Frame Gate 和 native-buffer path。C++ desktop capturer 会增加 ObjC++ bridge，并削弱已确认的 dirty-rect 设计。

## 系统边界

```text
Receiver process                       Sender process
┌──────────────────┐                 ┌──────────────────────┐
│ role/session UI  │                 │ role/source/profile UI│
│ URLSession WS    │◀──── WS/WSS ───▶│ URLSession WS         │
│ PeerConnection   │◀══ DTLS-SRTP ══▶│ PeerConnection        │
│ H.264 decoder    │                 │ H.264 encoder         │
│ metrics renderer │                 │ RTCVideoSource        │
│ RTCMTLNSVideoView│                 │ Frame Gate            │
└──────────────────┘                 │ ScreenCaptureKit      │
                                     └──────────────────────┘
              │                                 │
              └──────────────┬──────────────────┘
                             ▼
                  Go signaling service
                  pairing + transparent relay

production-relay media: both peers ⇄ coturn TURN/UDP ⇄ both peers
direct-baseline media: local host/direct UDP only
```

Go signaling 和 coturn 是独立服务。Signaling server 不接触媒体、不生成或改写 SDP、不持有 TURN credential。coturn 不负责配对或身份认证。

## Repository 与构建

项目是一个 monorepo：

```text
apps/macos/                         XcodeGen project 与 Swift/ObjC source
server/                             Go signaling module
config/cast-tuning.default.json     非敏感 WebRTC 调优基线
config/runtime.example.json         无凭据的 runtime config 模板
scripts/bootstrap-webrtc.sh         校验并解压本地 XCFramework
scripts/run-local-signaling.sh      本机 signaling 入口
scripts/run-dual-client.sh          两个独立 app process 的验收入口
deploy/k3s/                         可选 ClusterIP/Ingress manifests
docs/                               设计、计划、运行与调优文档
artifacts/SHA256SUMS                release asset 权威 checksum
Vendor/WebRTC.xcframework           bootstrap 生成并被 Git 忽略
```

XcodeGen `project.yml` 是 Xcode project 的 source of truth；生成的 `.xcodeproj` 也提交，方便直接打开。目标为 macOS 14.0，Swift 6 language mode 使用主线程隔离与显式 concurrency boundary。App 使用 SwiftUI 管理状态和表单，用 `NSViewRepresentable` 包装 `RTCMTLNSVideoView`；ScreenCaptureKit、CoreMedia、CoreVideo、AppKit 和 private CoreGraphics interface 放在专用 adapter 中。

指定 XCFramework 不提交到 Git。`bootstrap-webrtc.sh` 先用 `artifacts/SHA256SUMS` 校验 zip，再解压到 `Vendor/`；缺失或 checksum 不匹配时 build 明确失败。framework 在 app build 阶段 embed and sign。

Runtime config 默认从 `--config <absolute-path>` 读取，未传时读取 `~/Library/Application Support/WebRTCScreencast/runtime.json`。TURN username/password 只存在 ignored runtime file，不写进 source、Xcode build setting、Info.plist、signaling payload、日志或诊断 bundle。配置载入后产生一个排除 secret value 的 canonical effective-config hash。

## macOS client 组件

### App shell 与 session state

`SessionCoordinator` 是 UI 使用的单一会话入口，状态为：

```text
idle → connectingSignaling → waitingForPeer → negotiating
     → connected → ending → idle
                        ↘ failed
```

Receiver 先连接并申请配对码，进入 `waitingForPeer`。Sender 连接、提交配对码，收到 paired event 后创建 H.264 send-only offer。Receiver 应用 offer、创建 recv-only answer。任一 signaling、SDP、ICE 或 capture 错误都变成带稳定 error code 的 session event；结束会话必须停止 stats timer、capture stream、renderer attachment、PeerConnection、WebSocket 和 virtual display。

同一 process 不允许同时成为 Sender 和 Receiver，也不允许会话中途交换角色。两个 process 通过 launch argument `--role sender|receiver`、`--profile direct-baseline|production-relay` 和同一 runtime config 自动进入对应流程；没有 argument 时由 UI 选择。

### Screen source

`ScreenSourceProvider` 暴露稳定的 `CaptureTarget`，隐藏主屏查询和 virtual display private API：

- `MainDisplayMirrorProvider` 解析当前 main display，构造 ScreenCaptureKit filter。只在显式本地测试配置中按 PID/window 排除 Receiver，并记录 exclusion。
- `VirtualExtendedDisplayProvider` 动态调用 `CGVirtualDisplayDescriptor`、`CGVirtualDisplay`、`CGVirtualDisplaySettings` 和 `CGVirtualDisplayMode`，创建 1920×1080、1×、60 Hz display。private declarations 与生命周期只存在于该 provider；创建失败时返回可见错误并允许用户选择已有 display fallback。

Virtual display object 必须被强引用到 session 结束。退出、失败或 stop 时释放对象，随后等待 display removal notification；诊断记录创建耗时、display ID、effective logical/pixel size、scale 和 cleanup 结果，不记录其它 display 上的内容。

### ScreenCaptureKit 与 Frame Gate

`ScreenCaptureSource` 配置：1920×1080、NV12 video range、max 15 fps、nominal source resolution、`queueDepth=3`、cursor visible、`preservesAspectRatio=true`。主屏非 16:9 时根据 source aspect 计算 `destinationRect`，由 ScreenCaptureKit 做一次等比例 1080p downscale，并在黑色 1920×1080 IOSurface 中 letterbox；virtual display 正好填满输出。callback 只解析 frame status、timestamp、content rect、dirty rect 和 pixel buffer，然后交给专用 serial media queue。

`DirtyRegionAnalyzer` 使用 sweep-line 计算 dirty rect clipped union area，不能用面积简单相加或 bounding box 代替。`FrameGate` 维护 15/15/5/idle 四种提交状态，遵循“升档快、降档慢”，且始终 latest-frame-wins：

- dirty ratio ≥ 0.5% 立即进入 motion 15 fps；0–0.5% 的非零变化进入 detail 15 fps。
- 低变化持续 500 ms 后保持 detail 15 fps，再持续 800 ms 降到 5 fps；完全静止 300 ms 后进入 idle。
- idle 收到任意变化立即恢复 15 fps。
- Gate 只控制向 `RTCVideoSource` 的提交，不动态修改 ScreenCaptureKit cadence。

通过 `RTCVideoCapturer(delegate: videoSource)` 交付 `RTCVideoFrame(buffer: RTCCVPixelBuffer(...))`，保持 NV12 native-buffer path。复制主屏幕另用 96×54 luma grid 判断视觉稳定性：连续 600 ms 的 changed-sample ratio 不超过 2% 时，通过 CastTuning live patch 把 WebRTC source/sender 限到 1 fps、保持 5 Mbps，并在提交刷新帧前请求 IDR；变化超过 8% 时恢复 15 fps。2%/8% hysteresis 允许 cursor 和局部 UI 微动而不反复切档。这条清晰度策略不修改 ScreenCaptureKit cadence，也不用于 virtual display。

M150 zero-hertz adapter 在 idle 期间约每秒重发最后一帧，这种行为可以接受，因此不另造 heartbeat。当前 ObjC/CastTuning 接入尚未把 `min_fps=0` 应用到 source constraints；static-clarity 模式实际由 live `max_fps=1` 产生约 1 fps 输出，补齐 zero-hertz adapter 仍记入 follow-up。

### WebRTC session 与 H.264 policy

`WebRTCSession` 独占 PeerConnection factory、PeerConnection、transceiver、track 和 CastTuning controller。Factory 使用 `RTCDefaultVideoEncoderFactory`、`RTCDefaultVideoDecoderFactory` 和指定 M150 `RTCCastTuningFactoryBuilder`。

Video transceiver 使用 Unified Plan。Sender direction 为 send-only，Receiver 为 recv-only。创建 offer/answer 前，从 factory video capabilities 中筛出 H.264、`packetization-mode=1` 的 capability，并通过 `setCodecPreferences` 只保留 H.264；如果 capability 不存在则会话失败，不能静默协商 VP8/VP9/AV1。初始 profile 使用 Constrained Baseline，Constrained High 只作为可选实验配置。

当前 tuning 为 1920×1080、max 15 fps、min/start/max bitrate 400 Kbps/3 Mbps/5 Mbps、max QP 32、screen content、maintain-resolution、NACK+RTX、FEC off。该参数优先保证真实 macOS 桌面的文字清晰度；当前 WebRTC binary 自己负责 VideoToolbox realtime 和禁止 frame reordering，Apple `EnableLowLatencyRateControl` 不在一期伪装成已启用。

`direct-baseline` 使用 `RTCIceTransportPolicyAll`、禁用 TCP candidate 且不配置 TURN。`production-relay` 使用 `RTCIceTransportPolicyRelay`、禁用 TCP candidate且仅配置 `turn:<host>:<port>?transport=udp`。建立连接后 `ICEPathVerifier` 必须从 RTCStats 和 candidate-pair event 验证 requested profile：production path 的 local/remote candidate 都必须为 relay，relay protocol 必须为 UDP；不符合时 UI 和日志显示 profile violation，而不是把连接标为验收成功。

### Receiver render

Remote H.264 video track 同时 attach 到：

- `RTCMTLNSVideoView`，负责 Metal 播放；
- `MetricsVideoRenderer`，只统计 callback cadence、frame size、rotation、重复 timestamp 和最后帧停留时间，不复制 pixel data。

收到新 receiver/transceiver 时只接受第一条 video track。额外 track 属于 protocol violation 并记录错误。

## Signaling protocol 与 server

Server 使用 Go 1.24、`net/http`、`log/slog` JSON handler 和当前维护的 `github.com/coder/websocket`。HTTP endpoints：

- `GET /healthz`：只返回 process readiness，不暴露 session。
- `GET /metrics`：Prometheus text format 的连接、配对、消息、拒绝、过期和当前 pending/session gauge。
- `GET /ws`：支持 plain WS；放在 TLS ingress 后自然成为 WSS。Server 本身不强制 TLS 或校验 Origin 作为身份。

每个 WebSocket JSON envelope 包含 `version=1`、client-generated `message_id`、`type` 和 typed `payload`。一期消息集合固定为：

```text
receiver.register → receiver.registered
sender.join       → session.paired
sdp.offer         → transparent peer relay
sdp.answer        → transparent peer relay
ice.candidate     → transparent peer relay
ice.complete      → transparent peer relay
session.hangup    → transparent peer relay + cleanup
error             ← stable code, safe message, related_message_id
```

Receiver register 后 server 生成 8 位 Crockford Base32 code 和 opaque session ID。Code 只使用 `0123456789ABCDEFGHJKMNPQRSTVWXYZ`，未配对 10 分钟过期；Sender 成功 join 后立即从 pending-code index 删除，因此不能被第二个 Sender 重用。Session 只存在内存；任何一端断开都会通知另一端并删除 session，一期不 resume。

同一 connection 只能声明一个 role。未配对前只能发送与当前阶段相符的消息；配对后 SDP/ICE/hangup 只转发给绑定 peer。Server 验证 envelope、消息大小、SDP/candidate 字段长度和顺序，但不解析或改写 SDP。默认 message limit 为 256 KiB，WebSocket 总连接上限 2,000，pending code 上限 1,000，active session 上限 1,000；HTTP server 有 read-header、idle 和 graceful-shutdown deadline。WebSocket upgrade 前先执行全局连接容量和按来源建连 token-bucket；register/join 使用独立的来源 bucket。只有 immediate peer 位于显式 `TRUSTED_PROXY_CIDRS` 时，来源解析才从 `X-Forwarded-For` 右向左跳过可信代理，直连请求不能伪造 header。Join code 错误不泄露“存在但已占用”等可枚举状态。

每个 peer 只有一个 reader loop 和一个 bounded writer queue；慢消费者导致该 session 明确关闭，不能阻塞 registry。Ping/pong 用于发现 dead peer。Registry 的 create/join/remove/expire 是单一 owner goroutine 或 mutex 下的原子操作，保证 code 只能消费一次。

## Observability

### Client events 与 samples

`MetricsRecorder` 写 append-only JSONL。每条记录包含 schema version、record kind、event name、session ID、role、requested ICE profile、effective config hash、config revision、build version、wall-clock ISO-8601 和 monotonic elapsed time。Secret、完整 pairing code、SDP、ICE candidate string 和 TURN credential 永不进入 record。

事件立即记录：app/session lifecycle、capture permission、virtual display create/remove、signaling state、offer/answer apply、ICE gathering/connection/selected pair、DTLS/PeerConnection state、track attach、profile verification、error 和 export。

周期 sample 默认 1 秒：

- capture：callback/submitted/dropped fps、frame age、frame status、pixel format、dirty rect count/ratio、Frame Gate state/residence。
- outbound：frames encoded/sent、encode time、QP、keyframes、quality limitation、target bitrate、NACK/PLI/FIR、RTX、encoder implementation。
- path：candidate types、protocol、relay protocol、network type、RTT、available outgoing bitrate、loss/jitter。
- inbound/render：frames received/decoded/dropped/rendered、decode time、jitter-buffer delay、freeze/pause、NACK/PLI/FIR、decoder implementation、render cadence/frame age/size。

RTCStats values 是动态字典，`RTCStatsNormalizer` 负责类型安全提取并在字段缺失时输出 null + capability event，而不是 crash 或伪造 0。JSONL 额外记录 luma changed-sample ratio、visual stability/clarity mode、刷新成功/失败/恢复次数及 encoded/decoded keyframe counters，便于证明 static-clarity 刷新真正到达 Receiver。UI 只显示连接状态、selected path、capture/encode/render fps、bitrate、RTT、loss、QP 和 Frame Gate state 的小型现场面板；完整证据以 JSONL 为准。

`DiagnosticExporter` 生成结构化诊断 zip，包含 client JSONL、可安全导出的 CastTuning telemetry、server metrics snapshot（若可达）和 manifest/checksum。原始 `RTCFileLogger` 与 RTC event log 会包含无法可靠脱敏的 ICE candidate、ufrag/password，因此一期禁用且 exporter 发现这类历史文件时 fail closed。导出前还运行 runtime credential scan，发现原文时中止并报告错误。

Go server 使用 JSON structured event log 和 Prometheus counters/gauges/histograms。配对/会话日志包含 server 分配的完整 opaque session ID，客户端 JSONL 使用同一个 ID，三方证据可可靠关联；日志不包含 pairing code、SDP、candidate 或 credential。

## UI

UI 只服务终端任务，不显示设计说明或验收文字：

- Start：选择 Sender/Receiver、signaling URL 和 ICE profile。
- Receiver：显示配对码、连接状态、video canvas、主要 metrics、结束和导出。
- Sender：输入配对码、选择主屏复制/虚拟扩展屏、开始/停止、主要 metrics 和导出。
- Error：给出稳定错误说明和可执行动作，例如打开 Screen Recording settings、重试 virtual display、重新配对或检查 TURN 配置。

生产中继是默认 profile；direct baseline 明确标为开发选项。TURN credential 不显示在 UI。

## Error handling 与 cleanup

错误分为 config、permission、signaling、negotiation、capture、ICE profile violation、renderer 和 export。每个错误有稳定 code、用户安全描述、底层原因与 recoverability。可重试动作只重建受影响 session，不复用已消费 pairing code。

Cleanup 是幂等操作，按顺序停止 metrics timer、capture、track renderer、PeerConnection、signaling、virtual display 和 file writer。App termination 复用同一 cleanup path。Server 在 SIGINT/SIGTERM 时停止接收新连接、通知并关闭 active WebSocket、等待 bounded grace period 后退出。

## Testing 与一期验收

### Automated

- Go unit/race tests：pairing code alphabet/TTL/one-time consumption、并发 join、disconnect cleanup、protocol validation、limits、slow peer 和 metrics。
- Go WebSocket integration tests：真实 `httptest.Server` 下 Receiver register、Sender join、offer/answer/ICE relay、hangup、expiration 和 malformed message。
- Swift unit tests：runtime config redaction/hash、signaling Codable、session state machine、dirty union area、Frame Gate hysteresis、letterbox geometry、ICE profile configuration、RTCStats normalization 和 diagnostic secret scan。
- Xcode build/test：arm64 Debug app、unit tests、framework embed/sign 检查。

### 单机 E2E

验收脚本启动 Go server、Receiver process 和 Sender process，不能使用进程内 loopback：

1. `direct-baseline` 完成 receiver-first pairing、H.264 negotiation、主屏或 virtual display capture、decode/render，导出两端 metrics，并证明 selected path 不是 relay。
2. `production-relay` 强制 relay-only + TURN/UDP，完成相同闭环，并从 RTCStats 证明 selected candidate 使用 relay/UDP。
3. 两种 source mode 至少分别完成一次 start/stop，virtual display 在 stop 后移除。
4. 诊断 bundle redaction scan 通过，server log 不出现 SDP、candidate、pairing code 或 TURN credential。

一期不要求双机 LAN、TURN/TCP、内容 corpus、长时间稳定性、画质阈值或 glass-to-glass latency 门槛。因为 Screen Recording permission、private display API 和公网 coturn 是真实系统边界，最终 E2E 必须在本机 app 与真实 TURN 上执行；无法自动授权的系统 prompt 由 runbook 明确记录。

## Deployment

Go server 提供单 binary 和 container image。示例 K3s manifest 部署到 `apps` namespace，普通 ClusterIP + Traefik Ingress，并使用 `cast.example.com` 与示例 TLS secret；同一 binary 在本机可以 plain `ws://127.0.0.1:<port>/ws` 运行。Server 不使用 coturn 的 hostNetwork、listener 或 relay ports。

部署变更不自动执行到任何 K3s；先生成并通过 `go test`、container build、manifest schema/render 校验。真实 apply 是独立的外部状态变更，执行前应在目标部署环境中完成影响和 rollback 审核。

## 明确不在一期

- Apple `EnableLowLatencyRateControl` WebRTC rebuild。
- 动态降低 ScreenCaptureKit cadence、全局键鼠监听、Input Monitoring/Accessibility 权限。
- 临时 TURN credential、用户账号、session resume、持久化 registry。
- 音频、双向视频、多人会话、会话中角色交换、远程键鼠控制。
- TURN/TCP、生产 direct path、双机性能结论、内容 corpus 和画质/延迟硬门槛。
- temporal layers、LTR、自定义 FEC、receiver-aware layer dropping。

## 兼容性与风险

- `CGVirtualDisplay` 是 private API。所有调用隔离在 provider，OS update 后必须重新跑 create/apply/remove smoke；不可用时仍可选择已有 display，但这不等价于 app 创建虚拟扩展屏。
- 单机经公网 TURN 依赖 NAT hairpin、coturn UDP listener 与 relay range。Relay-only 未成功时不能用 direct path 掩盖失败。
- M150 RTCStats 字段会随版本变化。Normalizer 记录 field capability，避免因缺字段使整条 metrics pipeline 失败。
- 本地固定 TURN credential 只适合受控设备。任何 app 对外分发前必须完成 time-limited credential follow-up。
- 同机 capture、encode、relay、decode 和 render 共用一台机器，性能数据不能外推为双机上限。

## 依据

- [`CONTEXT.md`](../../../CONTEXT.md)
- [`2026-07-13-feasibility-baseline.md`](../../research/2026-07-13-feasibility-baseline.md)
- [`2026-07-14-automated-media-baseline-design.md`](./2026-07-14-automated-media-baseline-design.md) — 一期闭环后的单机自动化延迟与画质数据里程碑。
- [`0001-use-private-api-for-virtual-extended-display.md`](../../adr/0001-use-private-api-for-virtual-extended-display.md)
- [`content-aware-capture-efficiency.md`](../../follow-ups/content-aware-capture-efficiency.md)
- [`apple-low-latency-rate-control.md`](../../follow-ups/apple-low-latency-rate-control.md)
- WebRTC M150 release `webrtc-m150.7871.3-eeca1bc-20260713-all`
- `github.com/coder/websocket` upstream README and API
- DeskPad MIT-licensed `CGVirtualDisplay` compatibility declarations and lifecycle example
