# DamageIdleDetector 实验结果（2026-07-18）

## 结论

新的 `DamageIdleDetector` 可以替换旧的 luma detector，并建议合入 `main`。

它解决的问题很具体：旧实现只有收到下一次屏幕帧回调时，才会检查“画面是否已经静止 600 ms”。屏幕真正停住后可能不再有回调，状态就会一直卡住，无法切到静态清晰模式。新实现使用 ScreenCaptureKit 的 dirty rect 判断屏幕是否变化，并用独立于新帧回调的 deadline 唤醒检查。画面停止变化约 600 ms 后，即使没有新回调，也能切到 STATIC；发生滚动、输入或鼠标移动时，立即恢复 ACTIVE。

实验结果支持上线：

- H.264 新旧 detector 各运行三轮，18 个预定操作全部被识别，18/18 marker 到达 Android。
- 新 detector 的 ACTIVE 恢复耗时为 18.1～86.1 ms；静止后 601.4～628.9 ms 进入 STATIC。
- STATIC/ACTIVE MaxQP 24/32 均正确应用，VideoToolbox 没有丢帧。
- 静态文字画质没有下降，码率也没有增加。
- H.265 使用 MaxQP 33/39 完成正式 smoke 和 final-code regression，两轮均通过。

三轮 H.264 的同一个 fast-scroll sequence 出现了接收侧延迟尖峰。发送端 detector 当时均在几十毫秒内恢复，延迟增加发生在后续传输或接收侧。按本次验收口径，单一 sequence 的此类尖峰可以接受，不作为 detector 上线阻断项；只有多个不同操作、多个 run 持续出现同类退化时才考虑回滚。

## 先看业务价值：投屏有多快

下面的端到端延迟从固定操作 marker 提交开始，到对应画面在 Android 接收端真正 render 为止。p50 代表多数时候的典型体验，p95 代表较差但仍经常需要面对的尾部体验。H.264 每组汇总 3 个 run、18 个操作；H.265 每个 run 有 6 个操作。

| 编码与 detector | 样本 | ACTIVE E2E p50 | ACTIVE E2E p95 | 首帧 | 怎么理解 |
|---|---:|---:|---:|---:|---|
| H.264 + 旧 detector D0 | 18 | 193.7 ms | 241.6 ms | 1385.4 ms（3 轮中位数） | H.264 参考线 |
| H.264 + 新 detector D1 | 18 | 192.3 ms | 397.5 ms | 1430.6 ms（3 轮中位数） | 典型延迟与 D0 持平；p95 被 3 个 run 中同一 fast-scroll 位置的接收侧尖峰拉高 |
| H.265 + 新 detector H1 | 6 | 161.2 ms | 203.1 ms | 1396.7 ms | 正式 smoke，六段稳定 |
| H.265 + 最终代码 H1 | 6 | 135.9 ms | 432.3 ms | 1450.2 ms | 典型延迟较低；一个 473.6 ms 接收侧尖峰拉高 p95 |

首帧约 1.4 秒包含 sender join、协商、encoder/decoder 启动和第一帧 render，不是滚动或打字时的持续交互延迟。本次关注的是更换 detector 后首帧不要明显变慢；D1 比 D0 增加 45.1 ms，在预设 100 ms 容差内。

这些数值不能直接得出“H.265 一定比 H.264 快”的结论：H.264 D0/D1 是交错重复的正式对照，H.265 是后续 smoke/regression，运行轮次也更少。它们能支持的结论是：最终 detector 在 H.264 和 H.265 上都能快速恢复 ACTIVE；两种 codec 的典型端到端响应都在约 136～194 ms，未观察到 codec 集成性阻塞。

为了判断尾部尖峰是不是 detector 引起的，又把端到端拆成了两段：

| 编码与 detector | marker → sender capture p50 / p95 | sender capture → Android render p50 / p95 |
|---|---:|---:|
| H.264 D0 | 25.3 / 75.8 ms | 154.8 / 205.4 ms |
| H.264 D1 | 54.2 / 79.6 ms | 139.8 / 363.8 ms |
| H.265 H1 | 55.7 / 62.8 ms | 107.3 / 144.3 ms |
| H.265 final-code H1 | 24.4 / 32.4 ms | 109.8 / 405.3 ms |

新 detector 的 sender capture p95 为 79.6 ms（H.264）和 32.4～62.8 ms（H.265），尖峰主要出现在 capture 之后的网络、接收和 render 段。因此本次不为了掩盖接收侧尾部延迟而增加 10 fps 过渡状态或更多 detector 阈值。

## 再看业务价值：静态文字清不清楚

画质不是只看一个分数。本次同时检查四类证据：

| 证据 | 看什么 | 本次结果 | 业务含义 |
|---|---|---|---|
| SSIM-Y | 接收画面亮度结构与发送参考图是否一致，越接近 1 越好 | H.264 D0 最差 0.6196，D1 最差 0.6205；H.265 为 0.6201～0.6202 | 新 detector 没有造成可测的结构退化；D1 比 D0 高 0.0009 |
| PSNR-Y | 接收画面亮度误差，dB 越高越好 | H.264 D0 12.69 dB，D1 12.79～12.80 dB；H.265 12.81 dB | D1 比 D0 高约 0.11 dB，没有画质倒退 |
| 人工原图检查 | 12px 中文、等宽代码、细竖线、输入文字及滚动后的稳定性 | 104 张图均可读；无持续模糊、block、ringing、ghosting、tearing、黑帧或陈旧帧 | 直接覆盖会议投屏最在意的“小字能不能读”和“动完后能不能恢复清楚” |
| QP / drop / 码率 | 静态/动态 MaxQP 是否真的生效，清晰度是否靠丢帧或加码率换来 | H.264 24/32、H.265 33/39 均绑定成功；VT drop 为 0；D1 峰值码率中位数比 D0 低约 10% | 静态清晰策略真实进入 encoder，且没有用更多码率或丢帧换结果 |

SSIM/PSNR 的绝对值看起来不高，是因为参考图与 Android 截图之间还包含缩放、letterbox 和色彩处理；它们适合在同一链路内做 D0/D1 相对比较，不适合拿来和离线编码论文中的原始帧分数横比。H.265 仍有既知的轻微色调差异，本实验没有把它误判成 detector 回归。

MaxQP 也不是跨 codec 的统一画质刻度。H.264 的 24/32 与 H.265 的 33/39 分别来自各自 codec 的经验区间，本表只证明 static/active 参数按设计生效，不能用数字大小直接判断 H.264 与 H.265 谁更清楚。

本轮没有测 OCR 字符准确率、VMAF 或主观 MOS，因此结论聚焦于“新旧 detector 是否退化”和“固定文档的小字是否可读”，不宣称已经完成 H.264/H.265 的全面画质排名。

## 本次 detector 改了什么

| | 旧 detector | 新 detector |
|---|---|---|
| 活动信号 | 每帧抽样亮度并比较像素 | ScreenCaptureKit `dirtyRects` |
| 进入静态 | 依赖下一次 capture callback 才检查 600 ms | deadline 到期主动检查，不等待新帧 |
| 恢复动态 | 亮度变化超过阈值 | 任意可见内容或 cursor damage |
| 帧率 | 状态机包含过渡状态 | ACTIVE 15 fps，STATIC 1 fps |
| 静态刷新 | 切换后请求清晰帧 | 缓存最后一张完整帧，切换时强制 IDR |
| 额外成本 | 每帧 luma sampling | 没有逐帧图像分析 |

状态只保留 ACTIVE 和 STATIC，没有增加 10 fps 过渡档、专用线程或新的 codec 分支。到期唤醒由系统共享 GCD queue 计时，detector 状态、缓存和 transition 仍全部在现有串行 `captureQueue` 上处理，因此不需要额外的锁。

macOS 偶尔会报告顶部近全宽的 capture status-strip repaint。该形状只被视为候选项；前后两张完整 NV12 buffer 的 Y/UV 有任意真实变化，或像素比较无法完成，仍按 ACTIVE 处理。这个限制避免把网页顶部的真实变化误判为系统 repaint。

## 实验方式

所有 run 使用相同环境和内容：

- Chrome `150.0.7871.129` 打开 localhost 上固定的 Kubernetes 中文 Deployment 文档。
- 分辨率为 1920×1080，接收端为 Android API 31 emulator。
- 媒体通过 production-relay UDP 发送。
- 开始静止 20 秒，随后每隔 8 秒执行三次快速滚动、一次慢速滚动、一次固定文字输入、一次固定鼠标路径，结束后再静止 20 秒。

H.264 对照保持 codec 和 QP 参数一致，只替换 detector：

- D0：旧 detector，STATIC/ACTIVE MaxQP 24/32。
- D1：新 detector，STATIC/ACTIVE MaxQP 24/32。
- 顺序为 `D0,D1 / D1,D0 / D0,D1`，各三轮。

H.265 先完成一轮正式 H1。Code Review 收紧 status-strip 像素核验后，只增加一轮同参数 final-code regression，确认最终代码仍能正常进入 STATIC；两轮均使用 STATIC/ACTIVE MaxQP 33/39，没有扩展 codec、QP 或 VideoToolbox 参数矩阵。

正式结果保存在 Git ignored 目录：

- `artifacts/damage-idle/experiments/20260718T075636Z/`
- `artifacts/damage-idle/experiments/20260718-final-code-h265/`

## H.264 对照结果

上面的业务总览把每组 18 个操作样本合并后直接计算 p50/p95；本节为了观察 run 间稳定性，汇总列采用“每轮先算 p95，再取三轮中位数”。因此 D1 的 397.5 ms 和 346.0 ms 是两种不同的聚合口径，不是数据冲突。

| 指标 | 旧 detector D0 | 新 detector D1 | 业务判断 |
|---|---:|---:|---|
| 首帧中位数 | 1385.4 ms | 1430.6 ms | 增加 45.1 ms，在 100 ms 容差内 |
| ACTIVE E2E p95 中位数 | 229.7 ms | 346.0 ms | 受单一接收侧 sequence 尖峰影响，不阻断 |
| 最大 render gap | 1000.0 ms | 741.9 ms | D1 更低；绝对值包含实验主动等待的 500 ms |
| 峰值码率中位数 | 4.80 Mbps | 4.31 Mbps | 没有增加 |
| VideoToolbox drop | 0 | 0 | 通过 |
| 最差 SSIM-Y | 0.6196 | 0.6205 | D1 高 0.0009，没有画质退化 |
| 最差 PSNR-Y | 12.69 dB | 12.79 dB | D1 高 0.11 dB，没有画质退化 |
| Android marker | 18/18 | 18/18 | 通过 |

这些数据说明，新 detector 没有用更高码率换取静态清晰度，也没有造成 VideoToolbox 丢帧。SSIM/PSNR 的绝对值受 sender 原图、Android 截图缩放和 letterbox 影响，本实验只比较同一链路下 D0 与 D1 的相对变化。

### Detector 是否按预期切换

三轮 D1 的六个预定操作都先进入 ACTIVE，恢复耗时为 18.1～86.1 ms，直接使用 15 fps。每次操作结束后，可明确配对的静止切换耗时为 601.4～628.9 ms，符合 600 ms 设计值。

每轮实际产生 13～14 次 ACTIVE、STATIC 和 clarity refresh，多于六个预定操作。这些额外切换来自实验 marker、截图和 Chrome compositor 的真实可见更新。新 detector 的业务规则是“有可见变化就进入 ACTIVE”，因此没有为了凑预设计数而过滤这些事件。所有 clarity refresh 均成功，失败数为 0。

第二次 fast-scroll 的异常 run 中，sender capture latency 为 25.8～78.5 ms，而 capture 到 Android render 为 313～374 ms。detector 已及时唤醒，尖峰位于后续链路。

### 每轮明细

| Case/run | 首帧 ms | ACTIVE E2E p95 ms | max render gap ms | 峰值码率 Mbps | VT drop | Marker | STATIC SSIM-Y / PSNR-Y |
|---|---:|---:|---:|---:|---:|---:|---:|
| D0 run-1 | 1385.4 | 195.2 | 1000.0 | 4.80 | 0 | 6/6 | 0.6197 / 12.69 |
| D0 run-2 | 1419.9 | 244.3 | 1000.0 | 4.50 | 0 | 6/6 | 0.6196 / 12.69 |
| D0 run-3 | 1034.2 | 229.7 | 1000.0 | 3.28 | 0 | 6/6 | 0.6197 / 12.69 |
| D1 run-1 | 1496.3 | 390.4 | 741.9 | 3.70 | 0 | 6/6 | 0.6205 / 12.80 |
| D1 run-2 | 1410.9 | 346.0 | 741.8 | 4.31 | 0 | 6/6 | 0.6205 / 12.80 |
| D1 run-3 | 1430.6 | 337.5 | 732.9 | 3.95 | 0 | 6/6 | 0.6209 / 12.79 |

## H.265 验证结果

| 指标 | 正式 H1 | final-code H1 |
|---|---:|---:|
| 首帧 | 1396.7 ms | 1450.2 ms |
| ACTIVE E2E p95 | 203.1 ms | 432.3 ms |
| 最大 render gap | 667.0 ms | 686.0 ms |
| 峰值码率 | 1.84 Mbps | 2.34 Mbps |
| VideoToolbox drop | 0 | 0 |
| Marker | 6/6 | 6/6 |
| STATIC SSIM-Y / PSNR-Y | 0.6201 / 12.81 dB | 0.6202 / 12.81 dB |
| QP binding | 33/39 applied | 33/39 applied |

正式 H1 的六次 ACTIVE 恢复耗时为 48.6～64.0 ms，静止切换为 610.7～625.4 ms。final-code H1 的恢复耗时进一步缩短到 18.2～33.8 ms，静止切换为 601.0～629.8 ms；15 次 ACTIVE、15 次 STATIC 和 15 次 clarity refresh 全部成功。

final-code H1 的第六个 sequence 接收 E2E 为 473.6 ms，其余五段为 104.8～308.6 ms；同一 sequence 的 sender detector 只用了 24.8 ms。它属于已接受的单一接收侧尖峰，不改变 detector 上线判断。

两轮 sender 实际输出均为 `video/H265`，VideoToolbox encoder 为 `com.apple.videotoolbox.videoencoder.ave.hevc`，网络路径为 relay/relay UDP。H.265 的 33/39 QP、keyframe 和 encoder session 均有 telemetry 绑定，不是只验证了协商结果。

## 原图检查

执行者用 original detail 检查了七个正式 run 的 sender 与 Android initial、fast-scroll、slow-scroll、typed、cursor、final，共 84 张图；另外检查 final-code H1 的 6 张 Chrome fixture、7 张 sender capture 和 7 张 Android decoded 图。总计 104 张。

固定文档的 12px 中文、等宽代码、细竖线和输入文字均可读，没有发现裁剪、黑帧、陈旧帧、block、ringing、ghosting、tearing 或持续模糊。typed marker 图可能只出现首个字符，这是 marker 在输入开始时提交的预期行为；cursor 和 final 图确认完整文本最终到达。Android HEVC 仍有既知的轻微色调差异，不属于 detector 回归。

### H.264 D0 / D1

![D0 initial](2026-07-18-damage-idle-detector/d0-initial.png)

![D0 fast scroll](2026-07-18-damage-idle-detector/d0-fast-scroll.png)

![D1 initial](2026-07-18-damage-idle-detector/d1-initial.png)

![D1 fast scroll](2026-07-18-damage-idle-detector/d1-fast-scroll.png)

![D1 cursor](2026-07-18-damage-idle-detector/d1-cursor.png)

![D1 final](2026-07-18-damage-idle-detector/d1-final.png)

### H.265 H1

![H1 initial](2026-07-18-damage-idle-detector/h1-initial.png)

![H1 final](2026-07-18-damage-idle-detector/h1-final.png)

## 隐私处理

原始 evidence 保持 Git ignored，不随提交发布。它可能包含本机绝对路径、emulator/ADB 运行细节、菜单栏或 Dock 等本地环境信息，因此不会直接提交。两次误在锁屏状态启动的无效 H.265 run 已从 workspace 移入废纸篓，不计入结果。

发布的八张 PNG 均从固定文档的 Android decoded/output frame 重新编码。metadata 不含作者、creator 或来源 URL；画面只包含开源文档、测试 marker、测试输入和黑色 letterbox，不包含用户名、邮箱、路径、凭据、设备标识、pairing code、私有网络地址或无关桌面内容。

配置 secret scanner 已检查正式结果目录、final-code 结果目录和 tracked diff，未发现配置中的 TURN username/password。

## 上线后的观察项

- 关注多个连续操作的 ACTIVE latency p95、VideoToolbox drop、render freeze 和 encoder session rebuild。单一 isolated spike 不触发 detector 回滚。
- 如果接收侧延迟在多个 sequence、多个 run 中持续增加，单独分析 transport 和 decoder，不向 detector 增加中间状态或更多阈值。
- 当前 render-gap window 从 marker 更新开始，而滚动 workload 会在 marker 后主动等待 500 ms。若未来继续使用 500 ms 绝对门槛，应先把测量起点移到真实滚动或输入开始时。
- 本次不改变 H.264/H.265 默认 codec policy，也不继续扩展 QP 或 VideoToolbox feature flags。
