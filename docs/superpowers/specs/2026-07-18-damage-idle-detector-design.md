# STATIC/ACTIVE Damage Idle Detector 设计

## 目标

为会议投屏提供可维护的两状态内容感知机制：任何屏幕变化都立即恢复 `ACTIVE` 的 15 fps 与 active MaxQP；连续 600 ms 没有 ScreenCaptureKit damage 后，即使不再收到 capture callback，也进入 `STATIC` 的 1 fps 与 static MaxQP，并提交一次清晰 IDR 刷新帧。

成功标准是修复当前 detector 卡在 settling 的根因，同时不增加专用线程、额外视觉分析开销、过渡帧率或 codec 参数分支。鼠标光标移动属于用户可感知 activity，必须立即进入 `ACTIVE`。

## 已比较方案

### 继续调节 luma sampler 阈值

保留 96×54 luma grid 并调整 dwell 或变化比例，无法解决静止后没有 callback 时计时条件永远不被求值的问题，而且继续支付每帧像素采样成本。不采用。

### dirty rect 与 luma detector 并行

dirty rect 用于快速唤醒，luma 用于确认静止，可以容忍异常 damage，但引入两套 activity 事实来源、冲突优先级和更多阈值。对当前主屏 ScreenCaptureKit 路径没有证据证明收益足以覆盖维护成本。不采用。

### dirty rect + quiet deadline（采用）

ScreenCaptureKit dirty rect 是唯一 activity 事实来源；串行 capture queue 上的 monotonic deadline 是唯一静止判定来源。该方案直接修复 callback-coupled timer，鼠标移动自然计为 activity，并删除 luma 分析成本。

## 状态与数据流

`DamageIdleDetector` 只包含 `active` 与 `staticClarity`：

- 初始状态为 `active`。
- `.started`、缺失 dirty metadata 或非空 dirty rect 都是 damage；空 dirty rect 不是 damage。
- 合法 damage 更新 `lastDamageMonotonicNs` 和 `quietDeadlineMonotonicNs`。若当前为 `staticClarity`，产生一次 `exitStaticClarity`；否则不重复产生 transition。
- quiet check 在 deadline 前不切换；到期且此后没有更新 damage 时产生一次 `enterStaticClarity`。
- 乱序 monotonic timestamp 不改变状态或 deadline。
- lifecycle generation 使 stop/restart 前安排的 quiet check 失效。

`ScreenCaptureSource` 的 ScreenCaptureKit callback 与 quiet check 都在现有串行 `captureQueue` 上执行，不增加 lock 或专用线程。callback 总是缓存最后一张完整 `CVPixelBuffer` 及构造 synthetic refresh 所需 metadata。检测到 damage 时，先向 WebRTC boundary 应用 `exitStaticClarity`，再提交当前真实帧。

quiet check 进入 STATIC 时，先应用 1 fps/static MaxQP 并强制 keyframe，再用缓存帧和新的 monotonic WebRTC timestamp 提交一次 synthetic clarity refresh。若没有缓存完整帧，不切换 STATIC，保持 ACTIVE。现有 `FrameGate` 继续独立决定普通 callback frame 是否提交；transition frame 不受 gate 丢弃。

## 接口与 telemetry

删除 `VisualStabilityDetector`、`LumaFrameSampler`、三态 `motion/settling/staticClarity` 和 changed-sample telemetry。业务类型改为：

```swift
enum ContentActivityMode: String, Equatable, Sendable {
    case active
    case staticClarity = "static_clarity"
}

enum ContentActivityTransition: Equatable, Sendable {
    case none
    case enterStaticClarity
    case exitStaticClarity
}
```

capture telemetry 固定输出：

- `content_activity_mode`
- `last_damage_monotonic_ns`
- `quiet_deadline_monotonic_ns`
- `active_transition_count`
- `static_transition_count`
- `synthetic_clarity_refreshes`

为让 1 Hz stats sampler 仍能验证亚秒状态门槛，snapshot 额外保留最近一次 ACTIVE 与 STATIC transition 的 monotonic timestamp；analyzer 对 timestamp 去重后还原每轮切换，不提高采样频率，也不增加编码侧工作。

现有 dirty rect、FrameGate、QP、VideoToolbox session、keyframe、drop、latency 与 bitrate telemetry 保留。`StaticClarityRefreshController` 和 sender boundary 使用新的两态类型，但保持 1/15 fps、active/static MaxQP 与失败重试语义不变。

## 失败语义与生命周期

- metadata 缺失时 fail active，不误降到 STATIC。
- STATIC policy 或 keyframe 应用失败时不提交 synthetic refresh，transition 留待安全重试；controller 保持或恢复 ACTIVE policy。
- ACTIVE policy 恢复失败时不发送当前真实帧，transition latch 留待下一 callback 重试，避免以 static policy 编码交互帧。
- stop 在 capture queue 上推进 generation 并清除缓存；旧 deadline 不得提交帧或改变 telemetry。
- 不使用 `1 → 10 → 15` 爬坡。只有端到端证据显示直接唤醒产生 dropped frame、队列或延迟尖峰时才另行设计。

## 验证与实验

单元测试只保护 detector、deadline scheduler 和 transition ordering 的行为契约。集成验证运行完整 macOS tests/build 与项目 `make verify`。

业务实验固定 Chrome 150.0.7871.129 和本地 Kubernetes 中文文档：20 秒初始静止；每隔 8 秒执行三次快速滚动、一次慢速滚动、一次文字输入、一次固定鼠标路径；20 秒最终静止。先用相同 H.264 24/32 参数比较旧 detector D0 与新 detector D1，各三次交错运行；D1 通过后仅做一次 H.265 33/39 smoke。

D1 必须交付六段 activity、每段立即 ACTIVE、最后 damage 后 600–900 ms STATIC、6 次 ACTIVE restore、7 次 clarity refresh，并满足既定 latency、freeze、drop、bitrate 和画质门槛。所有关键 sender/Android 图片使用原图逐张人工检查。若唯一失败是 600–1000 ms compositor 尾部 damage，仅将 quiet duration 调为 1000 ms 并重跑 D1 三次；不扩展其他状态、阈值或实验矩阵。

## 非目标

- 修改 H.264/H.265 MaxQP 数值、VideoToolbox rate control 或 codec preference；
- 新增设置 UI、专用 detector 线程或 10 fps 过渡；
- 改造 Android decoder、signaling、FrameGate 或无关 capture 结构；
- 为低概率边界增加与业务收益不成比例的防御代码。

## Execution findings

- 正式 D0/D1 需要运行相同的新 workload。实现前先归档当前 commit 构建出的 D0 app bundle；E2E runner 只增加显式 app-bundle 输入，不在最终产品中保留 legacy detector selector。
- 最终静态截图不能通过更新一个新 marker 触发，否则会人为增加第七次 ACTIVE。六个 activity 使用 sequence 2–7；最终图在第六轮重新进入 STATIC 后直接抓取，不再修改页面。
