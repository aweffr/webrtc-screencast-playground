# macOS 低延迟投屏可行性调研基线

本文记录 `webrtc-screencast-playground` 进入设计前已经核实的事实、当前可行的媒体链路，以及仍需确认的产品与工程决策。结论以 WebRTC M150 release、对应 upstream source、Apple 平台文档、现有 coturn runbook 和外部专家建议为依据。

## 当前结论

第一阶段可以使用同一个 macOS native app 同时承载发送端和接收端角色。发送链路采用 ScreenCaptureKit、应用层 Frame Gate、`RTCCVPixelBuffer`、WebRTC H.264 VideoToolbox encoder；接收链路采用 WebRTC H.264 VideoToolbox decoder 和 `RTCMTLNSVideoView`。项目最低系统版本需要设为 macOS 14，因为指定 WebRTC framework 的 deployment target 是 `14.0`。

现有公网 coturn 只能提供 TURN relay。它不处理 signaling、房间管理或客户端身份认证。跨网络自动建立会话仍需一个 signaling channel；固定 TURN 凭据仅适合本地开发和受控试验，不适合随可分发 app 一起固化。

“扩展屏”已经明确为客户端主动创建、由 macOS 识别为独立桌面的 Virtual Extended Display，不是采集一块已经存在的第二 display。当前公开 macOS SDK 没有对应的应用层 API；项目接受使用 private `CGVirtualDisplay` API、直接分发和系统升级兼容风险，并将其隔离在独立 provider 中。采集已经存在的 display 只作为 virtual-display creation 不可用时的 fallback。

已确认的一期范围是：接受 M150 zero-hertz adapter 每 1 秒重发最后一帧；不监听全局键鼠，也不动态降低 ScreenCaptureKit cadence。相关性能优化保留为独立 follow-up。

虚拟扩展屏的 logical workspace 和 backing pixels 均为 1920×1080、scale 1×。virtual display 以 60 Hz 运行，媒体采集与 H.264 编码上限为 30 fps。主屏复制不修改发送端显示设置，完整画面等比例适配到 1920×1080 stream，必要时 letterbox，不裁剪。HiDPI backing 与 1080p downsampling 留作后续画质实验。

同一个 app 在会话开始时选择 Sender 或 Receiver。每个 Casting Session 恰好包含一个 Sender 和一个 Receiver，只传输一路 Sender → Receiver 视频，不支持同时双向投屏或会话中途交换角色。控制、测量和恢复消息可以双向传输。

## Release 产物核验

指定的两个文件已经下载到 `artifacts/`，并通过 GitHub release 公布的 SHA-256：

| 文件 | 大小 | SHA-256 |
| --- | ---: | --- |
| `webrtc-m150-macos-arm64.tar.gz` | 247 MiB | `30f5542a763b448ba84efc51bbba06d26a3a10a35ecbf8609d798ebe879a77ef` |
| `WebRTC-m150-macos-universal.xcframework.zip` | 22 MiB | `b45ed23af9a11d83ff967f63a0cd4067842eac67a7a6862e66326e615e1b2031` |

arm64 tar 包内部 `SHA256SUMS` 全部通过。XCFramework 的根 binary 同时包含 `arm64` 和 `x86_64`，deployment target 为 macOS 14.0。两种架构都已完成 Objective-C import/link probe，arm64 probe 已在本机启动成功。framework 本身未签名，后续由 app 的 embed/sign 阶段签名。

应用工程优先使用 XCFramework。arm64 tar 包保留作静态库、完整 C++ headers、metadata、GN args 和 thin framework 的检查来源，不需要把两个大文件提交到 Git。

## 建议媒体链路

```text
SCDisplay / virtual display
  → ScreenCaptureKit (1920×1080, NV12, max 30 fps, queueDepth 3)
  → Frame Gate (dirty rect + hysteresis, latest frame wins)
  → RTCCVPixelBuffer / RTCVideoFrame
  → RTCVideoSource
  → VideoToolbox H.264
  → WebRTC RTP / ICE / DTLS-SRTP
  → direct path or coturn relay
  → VideoToolbox H.264 decoder
  → metrics renderer + RTCMTLNSVideoView
```

ScreenCaptureKit 可以在捕获阶段完成缩放和 NV12 转换。M150 的 `RTCCVPixelBuffer` 已实测支持 `420v`、`420f` 和 `BGRA`。当输出尺寸与 source adaptation 一致时，`CVPixelBuffer` 可以沿 native-buffer path 进入 encoder，避免主动转换成 I420。若后续由 WebRTC 再裁剪或缩放，链路可能需要额外 buffer 和 copy，因此 1920×1080 应尽量在 ScreenCaptureKit 层确定。

主屏幕不是 16:9 时，需要在“完整保留并 letterbox”与“裁剪到 16:9”之间选择。办公投屏默认应完整保留，避免菜单栏、Dock 或窗口边缘被裁掉。

## 外部专家策略评估

### 可直接进入第一阶段

- ScreenCaptureKit 最大采集帧率设为 30 fps，`queueDepth=3`，输出 1920×1080 NV12。
- 使用 dirty rect 的并集面积判断变化规模，不把重叠矩形面积直接相加。
- Frame Gate 放在 ScreenCaptureKit 与 `RTCVideoSource` 之间，只把选中的最新帧提交给 WebRTC。
- 升档快、降档慢；从 30 fps 逐级降到 15 fps、5 fps 和 idle，避免状态来回抖动。
- 发送源标记为 screen/text content，优先保持分辨率；H.264 使用 non-interleaved `packetization-mode=1`。
- VideoToolbox 使用 realtime、禁止 frame reordering；恢复优先采用 NACK+RTX，失败后 PLI/IDR，不启用 FEC。
- 起始试验码率可从 `min=400 Kbps`、`start=2.2 Mbps`、`max=3 Mbps` 开始。它比现有 `DETAIL_IDLE` 的 6 Mbps 上限更适合作为公网低延迟基线，但最终需要用真实办公内容校准。

### 调整后采用

M150 的 zero-hertz adapter 在 screen-content mode、source constraints 为 `min_fps=0`、`max_fps>0` 时启用。进入 idle 后，它会每 1 秒重发最后一帧，并非完全停止 RTP video；这一行为可以接受，也不需要额外实现 2–5 秒视频 heartbeat。实现后的实际日志显示当前 CastTuning ObjC 路径没有应用 `min_fps` constraint，因此当前 app 尚未启用该 adapter；一期由 Frame Gate 停止提交、Receiver 保留最后一帧，framework 接入差距已转入 follow-up。

第一阶段不动态把 ScreenCaptureKit 从 30 fps 降到 5 fps，也不监听全局键鼠。保持 capture 30 fps 可以在下一个系统画面更新时立即唤醒 Frame Gate；全局键盘监听会增加 Input Monitoring 或 Accessibility 权限。只有 CPU/GPU/功耗数据证明长期 30 fps capture 成本明显时，再增加第二层 capture cadence 调整。

该取舍已确认，后续工作见 [`content-aware-capture-efficiency.md`](../follow-ups/content-aware-capture-efficiency.md)。

低分辨率亮度差适合作为 dirty rect 不可靠时的第二信号。首版先记录 dirty ratio、误判样本和状态转换；出现视频、透明动画或合成层误判后，再用 Metal 或 Accelerate 实现 160×90 luminance/tile diff，避免在 capture callback 上加入未经证实的 CPU 工作。

Constrained High 的压缩效率通常优于 Constrained Baseline，但它属于 receiver compatibility 决策。macOS-to-macOS 首版可以把 Constrained High 作为实验 profile，同时保留 Baseline 对照；不能在尚未验证目标设备 decoder 前删除 Baseline。

### 当前 release 不能实现

外部建议要求在 `VTCompressionSessionCreate` 的 encoder specification 中设置 `kVTVideoEncoderSpecification_EnableLowLatencyRateControl`。指定 XCFramework 的 binary 未引用该 symbol，现有 CastTuning patch 也只设置 hardware policy、`RealTime`、frame reordering、frame delay、QP、slice 和 data-rate limit 等属性。

若要验证 Apple low-latency rate control，需要先修改 `my-webrtc-builds` 的 VideoToolbox hook、补充 capability/fallback telemetry、重新构建并发布 WebRTC。该工作已明确列为 follow-up；一期不改 WebRTC binary，只使用当前 release 完成端到端闭环并建立可测量基线。后续验证时不能在观测结果中把 stock realtime mode 与 Apple low-latency rate-control mode 混为一项。

时间分层、LTR token/ack 和 receiver-aware layer dropping 也没有被当前 ObjC WebRTC 接口与 CastTuning 封装为可直接启用的能力，暂不进入 minimal client。

## 连接、信令与 coturn

现有 coturn 配置已经核实：runtime file 字段完整、权限为 `0600`。当前终端没有配置 Kubernetes context，因此本次没有读取 workload 状态，也没有执行 TURN allocation smoke test。一期跨网只支持 TURN/UDP，真实验收需确认 ICE selected candidate 为 `relay` 且 relay protocol 为 UDP；TURN/TCP 不进入实现或验收范围。

`production-relay` profile 只配置：

```text
turn:<public-ip>:<port>?transport=udp
```

一期提供两种明确的 ICE 运行 profile。`direct-baseline` 允许 host/srflx direct UDP，仅用于本机对照和开发诊断，不代表两台设备的真实 LAN 性能，也不用于生产；`production-relay` 设置 relay-only policy 且只配置 TURN/UDP，防止运行时静默切换到 direct path 或 TURN/TCP。调优数据必须记录 requested profile、最终 candidate pair、local/remote candidate type、relay protocol 和 network type，否则无法确认测量对应哪条路径。

signaling 至少需要传递 session join、offer、answer、trickle ICE candidate、hangup 和错误。minimal 自动连接方案可使用一个轻量 WebSocket rendezvous service；手工复制 SDP 只适合底层 smoke test，不适合作为可重复的画质与延迟试验入口。

一期配套实现一个 Go signaling server，并与 macOS client 放在同一项目中。两端 PeerConnection 负责生成和应用 SDP offer/answer；server 通过 WebSocket 完成 rendezvous、透明转发 SDP 与 trickle ICE、管理配对和连接生命周期、执行输入校验与限流，并记录不含凭据和完整 SDP 的信令事件。server 不改写 SDP、不接触媒体，也不替代 coturn。

配对采用 Receiver-first：Receiver 向 signaling service 申请 8 位 Crockford Base32 一次性配对码并展示，Sender 输入该配对码加入。每个配对码只匹配一个 Sender 和一个 Receiver，成功配对后立即失效，未使用时 10 分钟过期。server 只在内存中保存待配对状态，一期断线后结束会话并重新配对，不实现 session resume。

一期不引入用户账号或长期 API key。持有 server 生成的一次性配对码即授权 Sender 加入对应会话，但不把它解释为用户身份认证。signaling transport 同时允许 `ws://` 和 `wss://`，TLS 不作为业务前置条件；公网默认部署仍可复用现有 Traefik TLS。创建配对码和尝试加入都需要按来源限流，并设置全局待配对会话上限、消息大小上限、读写 deadline 与 WebSocket ping/pong。原生客户端的 `Origin` 不能作为主要认证依据。事件日志只记录 session ID 前缀、事件、结果与必要的匿名化来源信息，不记录完整配对码、SDP、ICE candidate 或 TURN credential。

现有 K3s 已提供 `*.k3s.aweffr.cn` wildcard DNS、TLS certificate 和 Traefik HTTPS Ingress。signaling server 建议部署到 `apps` namespace，通过普通 ClusterIP Service 暴露为 `wss://cast.k3s.aweffr.cn/ws`，并提供不含内部状态的 `/healthz`；这只是公网部署默认值，server 和 client 同时支持无需 TLS 的 `ws://`。它不使用 coturn 的 `hostNetwork`、listener 或 relay port；WebSocket 与 TURN 保持独立故障域和运维入口。

一期只面向受控设备，继续使用现有固定 TURN username/password。凭据通过 ignored local configuration 注入 runtime config，不进入 source、Git history、日志、UI 或 signaling payload。客户端通过 `IceServerProvider` 边界取得 ICE server 配置，避免媒体会话直接依赖固定凭据的存储形式。若 app 后续交给不受控用户，应把 coturn 改为 `use-auth-secret` 等 time-limited credential 方案，并由受信 signaling/auth service 签发临时凭据；这属于部署与安全边界升级，不阻塞一期核心链路。

## 可观测性基线

可观测性分为 session event、周期指标和端到端测量，三类数据都带统一的 `session_id`、peer role、effective config hash、config revision、app/build version 和单调时间戳。

### 发送端

- ScreenCaptureKit callback fps、frame status、frame age、尺寸、pixel format、dirty rect count 和 dirty ratio。
- Frame Gate state、state residence time、submitted/dropped frame count、实际 submit fps、唤醒到首帧耗时。
- WebRTC `framesEncoded`、`framesSent`、`totalEncodeTime`、`qpSum`、`keyFramesEncoded`、`qualityLimitationReason`、NACK/PLI/FIR、RTX packet/byte count、target bitrate 和 encoder implementation。

### 传输

- signaling、ICE gathering、ICE connection、PeerConnection 和 DTLS state timeline。
- selected candidate pair、candidate types、protocol、relay protocol、current RTT、available outgoing bitrate、packets discarded on send、bytes/packets sent and received。
- remote-inbound packet loss、jitter、RTT 和 WebRTC bandwidth/quality limitation changes。

### 接收端

- `framesReceived`、`framesDecoded`、`framesDropped`、decode fps、`totalDecodeTime`、`qpSum`、decoder implementation。
- jitter-buffer current/target/minimum delay、emitted count、packet loss、NACK/PLI/FIR、freeze/pause count。
- renderer callback fps、frame age、重复 frame、最后一帧停留时间、view size 与实际 video size。

CastTuning JSONL 继续记录配置 apply、hash、revision 与失败；app 自己的 metrics writer 负责 capture、RTCStats、renderer 和 signaling。周期采样默认 1 秒，状态变化和错误按事件立即记录。实时 dashboard 用于现场判断，完整 JSONL/诊断 bundle 用于离线对比，不能只保留 UI 上的瞬时数字。

RTCStats 可以分解 encode、network、jitter buffer 和 decode 行为，但不能单独给出可靠的 glass-to-glass latency。两个设备的 monotonic clock 不共享时间基准，RTP timestamp 也不等于可直接比较的 wall clock。验收阶段需要单独的 debug measurement：在发送画面叠加可识别 frame marker/timestamp，并在接收 renderer 记录识别时刻；最终关键结果可再用高帧率相机复核。

## 一期闭环验收

一期只要求当前一台 Mac 同时运行发送端和接收端，分别用 `direct-baseline` 与 `production-relay` 建立完整链路。两种 profile 都必须完成 pairing、SDP/trickle ICE、H.264 capture/encode、transport、decode/render，并连续采集 sender、receiver、signaling 和 selected candidate metrics。验收重点是链路真实闭合、profile 与实际 candidate path 一致、诊断数据可导出；暂不要求构造静态文字、快速滚动、窗口拖动、1080p 动态视频或 idle-to-motion 等内容 corpus，也不设置画质和 glass-to-glass latency 的硬门槛。

同机 `direct-baseline` 只能证明 direct UDP 分支和指标采集可工作，不能外推为两台机器的 LAN 基线。`production-relay` 必须通过 ICE policy 强制使用公网 coturn TURN/UDP；不能仅凭配置了 TURN URL 就认定流量已经过 relay。

单机验收启动两个独立 app process，一个选择 Sender、另一个选择 Receiver；两者分别持有真实 PeerConnection，并经真实 signaling service 配对，不在单个进程内增加 loopback-only media path。主屏复制的本地测试配置允许 Sender 从 ScreenCaptureKit filter 排除 Receiver process/window，避免递归投屏，并把该排除项记录到 effective config；虚拟扩展屏测试时 Receiver 保持在未被采集的主屏。

## 已确认的一期边界

核心业务术语、画面来源、单向媒体角色、Receiver-first 配对、Go WebSocket signaling、固定 TURN credential 的受控设备边界、`ws://`/`wss://` transport、TURN/UDP-only 生产路径、单机双进程验收与一期可观测性范围均已完成对齐。Apple low-latency rate control、动态 ScreenCaptureKit cadence 和全局输入事件唤醒保留为 follow-up。

## 参考资料

- [WebRTC M150 release](https://github.com/aweffr/my-webrtc-builds/releases/tag/webrtc-m150.7871.3-eeca1bc-20260713-all)
- [Apple: Capturing screen content in macOS](https://developer.apple.com/documentation/screencapturekit/capturing-screen-content-in-macos)
- [Apple WWDC22: Take ScreenCaptureKit to the next level](https://developer.apple.com/videos/play/wwdc2022/10155/)
- [Apple WWDC21: Explore low-latency video encoding with VideoToolbox](https://developer.apple.com/videos/play/wwdc2021/10158/)
- [Apple: VideoToolbox compression properties](https://developer.apple.com/documentation/videotoolbox/compression-properties)
- [WebRTC M150 retained reference sources](../../../my-webrtc-builds/references/M150/README.md)
- [Coturn TURN runbook](/Users/aweffr/developer/aweffr/k3s-playground/docs/coturn-runbook.md)
- [DeskPad](https://github.com/Stengo/DeskPad)
