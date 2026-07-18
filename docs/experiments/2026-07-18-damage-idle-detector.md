# DamageIdleDetector 实验结果（2026-07-18）

## 结论

`DamageIdleDetector` 解决了旧 detector 的核心活性问题：屏幕停止产生 capture callback 后，仍能在现有 `captureQueue` 上按时进入 STATIC；STATIC 下出现任意真实 dirty rect 时，直接恢复 15 fps 与 active MaxQP。实现没有新增线程、10 fps 过渡态或图像采样成本。

本轮不能宣称 D1 已通过完整产品门禁，也不运行 H.265 smoke test。两个有效 D1 run 的六个业务动作都在 16.2～79.0 ms 内恢复 ACTIVE，QP 绑定正确、VideoToolbox drop 为 0，静态画质与 D0 基本持平；但 Chrome 的 scrollbar/compositor 尾部更新和截图动作也会产生真实 dirty rect，使每轮实际发生 14 次 ACTIVE、14 次 STATIC clarity refresh，而不是预设的 6/7。过滤这些更新会违反“任意可见 damage 立即 ACTIVE”的业务契约，因此没有为了通过实验修改 detector。

当前实现不能按原计划直接合入 `main`。现有证据足以支持 detector 行为契约和运行时快速恢复，但不足以完成正式 E2E 验收：D1 缺少第三个有效 run、exact-count gate 与真实 dirty-rect 语义冲突、render-gap 未被有效测量，而且合入最新主线 color-range/Rec.709 capture metadata 后的组合二进制尚未重跑 D0/D1。除非负责人明确批准这些 gate waiver，否则 feature branch 保持未合入；本轮也不授权扩大 codec/QP 实验或宣称“端到端性能已经优于 D0”。

## 固定实验

- 原始结果目录：`artifacts/damage-idle/experiments/20260718T050753Z/`（Git ignored）
- 实验代码提交：前三个有效 run 为 `29b8b1ccee5427057cb218e74a53143115690562`；D0 run-3 为只修正实验证据保留逻辑的 `34268be1335adb87e890c2ef65bf31f5132bf9be`
- Chrome：`150.0.7871.129`
- Android：API 31、1920×1080 emulator
- 网络：production-relay UDP
- 内容：本地 Kubernetes 中文 Deployment 文档
- H.264 参数：D0 与 D1 均使用 STATIC/ACTIVE MaxQP 24/32
- 动作：初始静止 20 秒；每 8 秒执行三次固定快速滚动、一次慢速滚动、一次固定文字输入、一次固定鼠标路径；最后静止 20 秒

顺序按 `D0,D1 / D1,D0 / D0,D1` 执行。D0 得到 3 个可分析 run；D1 得到 2 个可分析 run。D1 run-3 的两次允许 attempt 分别因 emulator 消失、receiver 无法注册而失败；按预设上限停止，没有第三次重试。由于 D1 不具备三个有效 run 且 detector exact-count gate 失败，H1 未运行。

## 运行结果

| Case/run | 首帧 ms | ACTIVE E2E p95 ms | 峰值 bitrate Mbps | VT drop | Marker | STATIC SSIM-Y / PSNR-Y | 人工六阶段 |
|---|---:|---:|---:|---:|---:|---:|---|
| D0 run-1 | 1186.6 | 1832.3 | 4.43 | 0 | 6/6 | 0.6195 / 12.69 | 通过 |
| D0 run-2 | 1512.6 | 2946.9 | 4.58 | 0 | 5/6 | 0.6196 / 12.68 | 缺 fast-scroll Android 图 |
| D0 run-3 | 1506.8 | 2340.1 | 4.06 | 0 | 5/6 | 0.6195 / 12.69 | 缺 fast-scroll Android 图 |
| D1 run-1 | 1307.3 | 2517.1 | 4.68 | 0 | 6/6 | 0.6193 / 12.69 | 通过 |
| D1 run-2 | 1404.6 | 1977.0 | 3.93 | 0 | 6/6 | 0.6190 / 12.69 | 通过 |

D0 三次中位数与 D1 两次诊断性中位数如下。D1 只有两个有效 run，下面只用于判断是否出现明显退化，不是正式三轮 aggregate：

| 指标 | D0（n=3） | D1（n=2） | 观察 |
|---|---:|---:|---|
| 首帧 | 1506.8 ms | 1356.0 ms | 未见退化 |
| ACTIVE E2E p95 | 2340.1 ms | 2247.1 ms | 未见退化 |
| 峰值 bitrate | 4.43 Mbps | 4.30 Mbps | 未见退化 |
| VT drop | 0 | 0 | 持平 |
| 最差 SSIM-Y | 0.6195 | 0.6191 | 差 0.0004，在 0.002 门槛内 |
| 最差 PSNR-Y | 12.69 dB | 12.69 dB | 持平 |

SSIM/PSNR 的绝对值偏低，是因为 sender 原图与 1920×1080 Android 图存在缩放和 letterbox；本轮只使用同一测量链路下的 D0/D1 相对差异，不把绝对值解释为编码质量分数。

## Detector 证据

两个 D1 run 均满足：

- 六个预定业务动作全部观察到 ACTIVE 恢复，最大恢复时间分别为 76.8 ms 和 79.0 ms，直接使用 15 fps，没有 10 fps 中间态。
- STATIC/ACTIVE MaxQP 24/32 均与实际 encoder session、apply generation 绑定。
- 每个 STATIC transition 都触发一次成功 clarity refresh；failed refresh 为 0。
- 周期性 telemetry 可无歧义重建的 quiet latency 分别有 12 个和 10 个，范围为 600.6～630.0 ms。

每轮 transition/refresh 计数均为 14/14/14。逐时间线复核表明，额外切换对应真实 dirty rect：初始截图、快速滚动后的 scrollbar/compositor 尾部更新、后续截图以及结束阶段。部分尾部 damage 晚于滚动约 1.4 秒，不符合唯一预设的“只在 600～1000 ms 尾部 damage 时把 quiet duration 改为 1000 ms”条件，因此没有触发该迭代。

周期性 stats 不能可靠配对所有 transition 与当时的 `last_damage_monotonic_ns`：下一次 activity 可能先覆盖 last-damage 字段，之后 stats 才采样。本报告只采用可无歧义的正向样本范围，不使用 analyzer 产生的负值推断 detector 错误。行为测试覆盖无新 callback 到期、deadline 延后、旧 generation、乱序时间和 stop 后 callback。

## Render-gap 测量限制

本轮 `max_render_gap_ms` 约为 21.6～22.4 秒，不能解释为 Android 真正 freeze。现有 `AndroidMarkerProbe` 只在 marker 成功解码时调用 gap tracker；marker 暂时不可解码时，它把两个 marker observation 之间的间隔当成 frame gap。该数据不代表所有 render callback 的时间间隔，所以 500 ms render-gap gate 没有有效证据，既不能判 D1 通过，也不能据此判 D1 退化。

修正这一测量需要在每个 render callback 上记录 gap，并仅用 marker 界定 ACTIVE 窗口；这不影响 detector 实现正确性，但正式性能宣称前必须另行补测。本轮没有为补一个指标而扩大实现和实验轮次。

## 人工原图检查

执行者使用 original detail 逐张检查了五个有效 run 的 sender 与 Android initial、fast-scroll、slow-scroll、typed、cursor、final 图。所有实际存在的 Android 图中文字可读，没有明显 block、ringing、ghosting 或 tearing。D0 run-2/run-3 缺 sequence 4，按证据缺失记录为失败；没有用其他截图替代。

### D0 对照

![D0 initial](2026-07-18-damage-idle-detector/d0-initial.png)

![D0 fast scroll](2026-07-18-damage-idle-detector/d0-fast-scroll.png)

### D1 DamageIdleDetector

![D1 initial](2026-07-18-damage-idle-detector/d1-initial.png)

![D1 fast scroll](2026-07-18-damage-idle-detector/d1-fast-scroll.png)

![D1 cursor](2026-07-18-damage-idle-detector/d1-cursor.png)

![D1 final](2026-07-18-damage-idle-detector/d1-final.png)

## 隐私处理

原始 evidence 的失败 emulator log 曾包含本机 home 路径、用户名和 ADB public key，已就地替换为占位符。所有临时 `runtime.json` 已删除，配置 secret scanner 对完整结果目录通过。原始 evidence 仍保持 Git ignored。

提交的六张 PNG 经过重新编码、metadata 检查并以 original detail 再次检查；macOS 只保留了通用 `com.apple.provenance` 标记，不含用户数据。画面内容仅为固定开源文档、测试 marker 和模拟输入，没有用户名、本机路径、邮箱、凭据、设备标识、pairing code、私有网络地址或无关桌面内容。

## 当前决策

- 实现保留在 feature branch，未获得 gate waiver 前不合入 `main`。
- 若批准 waiver，合入的技术范围仍保持两态、600 ms quiet duration、STATIC 1 fps、ACTIVE 15 fps 和现有 24/32 H.264 MaxQP；不增加线程、过渡 fps 或 damage 过滤规则。
- 不运行 H.265 smoke test，不扩展 codec、QP 或 VideoToolbox feature matrix。
- 若不批准 waiver，应先修正 per-render callback gap 测量与非侵入式截图方式，再用当前 HEAD 补足三次有效 D1 并重新执行同一 D0/D1 aggregate gate；不要修改 detector 来适配实验计数。
