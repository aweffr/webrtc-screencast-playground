# DamageIdleDetector 实验报告（2026-07-18）

## 摘要

实验结果支持以 `DamageIdleDetector` 替换原有 luma detector。新实现能够在屏幕停止更新后按时进入静态清晰模式，并在滚动、输入或鼠标移动发生时恢复动态模式。H.264 对照实验未发现静态画质、码率或 VideoToolbox 丢帧退化；H.265 也完成了正式 smoke test 和最终代码回归验证。

原实现只在收到新的屏幕帧回调时检查 600 ms 静止条件。屏幕停止更新后可能不再产生回调，状态因而停留在过渡阶段，无法进入静态清晰模式。新实现使用 ScreenCaptureKit dirty rect 判断画面活动，并由不依赖新帧回调的 deadline 触发静止检查。最后一次画面变化约 600 ms 后，系统可以自行进入 STATIC；出现新的可见变化时，则立即恢复 ACTIVE。

主要结果如下：

- H.264 新旧 detector 各运行三轮，18 个预定操作全部被识别，18/18 marker 到达 Android。
- 新 detector 的 ACTIVE 恢复耗时为 18.1～86.1 ms；静止后 601.4～628.9 ms 进入 STATIC。
- STATIC/ACTIVE MaxQP 24/32 均正确应用，VideoToolbox 没有丢帧。
- 静态文字画质没有下降，码率也没有增加。
- H.265 使用 MaxQP 33/39 完成正式 smoke 和 final-code regression，两轮均通过。

三轮 H.264 的同一个 fast-scroll sequence 出现接收侧延迟尖峰。发送端 detector 均在几十毫秒内恢复，额外延迟发生在后续传输或接收环节。该现象只涉及单一 sequence，且不在 detector 所在环节，因此不构成本次替换的阻断条件。若后续在多个操作和多个 run 中持续出现同类退化，应再评估传输与接收链路。

## 端到端投屏表现

端到端延迟从固定操作 marker 提交开始计算，到对应画面在 Android 接收端完成 render 为止。p50 反映典型响应时间，p95 反映尾部延迟。H.264 每组包含 3 个 run、18 个操作样本；H.265 每个 run 包含 6 个操作样本。

| 编码与 detector | 样本 | ACTIVE E2E p50 | ACTIVE E2E p95 | 首帧 | 判断 |
|---|---:|---:|---:|---:|---|
| H.264 + 旧 detector D0 | 18 | 193.7 ms | 241.6 ms | 1385.4 ms（3 轮中位数） | H.264 参考线 |
| H.264 + 新 detector D1 | 18 | 192.3 ms | 397.5 ms | 1430.6 ms（3 轮中位数） | 典型延迟与 D0 持平；p95 被 3 个 run 中同一 fast-scroll 位置的接收侧尖峰拉高 |
| H.265 + 新 detector H1 | 6 | 161.2 ms | 203.1 ms | 1396.7 ms | 正式 smoke，六段稳定 |
| H.265 + 最终代码 H1 | 6 | 135.9 ms | 432.3 ms | 1450.2 ms | 典型延迟较低；一个 473.6 ms 接收侧尖峰拉高 p95 |

约 1.4 秒的首帧时间包含 sender join、协商、encoder/decoder 启动和第一帧 render，与滚动或输入过程中的持续交互延迟口径不同。D1 比 D0 增加 45.1 ms，低于 100 ms 的预设容差。

H.264 D0/D1 采用交错重复的正式对照，H.265 仅执行后续 smoke test 和 regression，运行轮次较少，现有数据不足以判断 H.265 的延迟必然优于 H.264。可以确认的是，最终 detector 在两种 codec 下均能及时恢复 ACTIVE，典型端到端响应为 136～194 ms，未发现 codec 集成问题。

端到端延迟进一步拆分为操作到 sender capture、sender capture 到 Android render 两段：

| 编码与 detector | marker → sender capture p50 / p95 | sender capture → Android render p50 / p95 |
|---|---:|---:|
| H.264 D0 | 25.3 / 75.8 ms | 154.8 / 205.4 ms |
| H.264 D1 | 54.2 / 79.6 ms | 139.8 / 363.8 ms |
| H.265 H1 | 55.7 / 62.8 ms | 107.3 / 144.3 ms |
| H.265 final-code H1 | 24.4 / 32.4 ms | 109.8 / 405.3 ms |

新 detector 的 sender capture p95 在 H.264 下为 79.6 ms，在 H.265 下为 32.4～62.8 ms。尾部尖峰主要发生在 capture 之后的网络、接收和 render 阶段，没有证据表明增加 10 fps 过渡状态或更多 detector 阈值能够改善这一问题。

## 静态文字画质

画质判断同时采用客观指标、编码器运行数据和原图人工检查。

| 证据 | 测量对象 | 结果 | 判断 |
|---|---|---|---|
| SSIM-Y | 接收画面亮度结构与发送参考图是否一致，越接近 1 越好 | H.264 D0 最差 0.6196，D1 最差 0.6205；H.265 为 0.6201～0.6202 | 新 detector 没有造成可测的结构退化；D1 比 D0 高 0.0009 |
| PSNR-Y | 接收画面亮度误差，dB 越高越好 | H.264 D0 12.69 dB，D1 12.79～12.80 dB；H.265 12.81 dB | D1 比 D0 高约 0.11 dB，没有画质倒退 |
| 人工原图检查 | 12px 中文、等宽代码、细竖线、输入文字及滚动后的稳定性 | 104 张图均可读；无持续模糊、block、ringing、ghosting、tearing、黑帧或陈旧帧 | 覆盖会议投屏中的小字可读性，以及画面变化后恢复清晰的能力 |
| QP / drop / 码率 | 静态/动态 MaxQP 是否生效，以及清晰度变化是否伴随丢帧或码率增加 | H.264 24/32、H.265 33/39 均绑定成功；VT drop 为 0；D1 峰值码率中位数比 D0 低约 10% | static/active 参数已应用于 encoder，且未增加码率或丢帧 |

参考图与 Android 截图之间包含缩放、letterbox 和色彩处理，因此 SSIM/PSNR 适合用于同一链路内的 D0/D1 相对比较，不适合与离线编码测试中的原始帧指标直接比较。Android HEVC 画面仍存在已知的轻微色调差异，该现象并非 detector 回归。

MaxQP 不是跨 codec 的统一画质刻度。H.264 的 24/32 与 H.265 的 33/39 分别依据各自 codec 的经验区间设定。实验数据能够证明 static/active 参数已经生效，但不能依据 QP 数值大小比较 H.264 与 H.265 的画质。

本轮未测量 OCR 字符准确率、VMAF 或主观 MOS。画质结论限于新旧 detector 的相对变化和固定文档的小字可读性，不构成 H.264/H.265 的全面画质排名。

## Detector 实现变化

| | 旧 detector | 新 detector |
|---|---|---|
| 活动信号 | 每帧抽样亮度并比较像素 | ScreenCaptureKit `dirtyRects` |
| 进入静态 | 依赖下一次 capture callback 才检查 600 ms | deadline 到期主动检查，不等待新帧 |
| 恢复动态 | 亮度变化超过阈值 | 任意可见内容或 cursor damage |
| 帧率 | 状态机包含过渡状态 | ACTIVE 15 fps，STATIC 1 fps |
| 静态刷新 | 切换后请求清晰帧 | 缓存最后一张完整帧，切换时强制 IDR |
| 额外成本 | 每帧 luma sampling | 没有逐帧图像分析 |

状态模型只保留 ACTIVE 和 STATIC，没有增加 10 fps 过渡档、专用线程或新的 codec 分支。系统共享 GCD queue 负责 deadline 计时；detector 状态、缓存和 transition 仍在现有串行 `captureQueue` 上处理，无需增加锁。

macOS 偶尔会报告顶部近全宽的 capture status-strip repaint。该形状只被视为候选项；前后两张完整 NV12 buffer 的 Y/UV 有任意真实变化，或像素比较无法完成，仍按 ACTIVE 处理。这个限制避免把网页顶部的真实变化误判为系统 repaint。

## 实验设计

所有 run 使用相同环境和内容：

- Chrome `150.0.7871.129` 打开 localhost 上固定的 Kubernetes 中文 Deployment 文档。
- 分辨率为 1920×1080，接收端为 Android API 31 emulator。
- 媒体通过 production-relay UDP 发送。
- 开始静止 20 秒，随后每隔 8 秒执行三次快速滚动、一次慢速滚动、一次固定文字输入、一次固定鼠标路径，结束后再静止 20 秒。

H.264 对照保持 codec 和 QP 参数一致，只替换 detector：

- D0：旧 detector，STATIC/ACTIVE MaxQP 24/32。
- D1：新 detector，STATIC/ACTIVE MaxQP 24/32。
- 顺序为 `D0,D1 / D1,D0 / D0,D1`，各三轮。

H.265 先完成一轮正式 H1。代码评审收紧 status-strip 像素核验后，增加一轮同参数 final-code regression，以确认最终代码仍能正常进入 STATIC。两轮均使用 STATIC/ACTIVE MaxQP 33/39，没有扩展 codec、QP 或 VideoToolbox 参数矩阵。

正式结果保存在 Git ignored 目录：

- `artifacts/damage-idle/experiments/20260718T075636Z/`
- `artifacts/damage-idle/experiments/20260718-final-code-h265/`

## H.264 对照结果

端到端投屏表现一节将每组 18 个操作样本合并后计算 p50/p95。下表用于观察 run 间稳定性，采用“每轮计算 p95，再取三轮中位数”的口径。因此，D1 的合并样本 p95 为 397.5 ms，三轮 p95 中位数为 346.0 ms。

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

新 detector 未通过提高码率换取静态清晰度，也未造成 VideoToolbox 丢帧。SSIM/PSNR 的绝对值受 sender 原图、Android 截图缩放和 letterbox 影响，此处只比较同一链路下 D0 与 D1 的相对变化。

### 状态切换结果

三轮 D1 的六个预定操作都先进入 ACTIVE，恢复耗时为 18.1～86.1 ms，直接使用 15 fps。每次操作结束后，可明确配对的静止切换耗时为 601.4～628.9 ms，符合 600 ms 设计值。

每轮实际产生 13～14 次 ACTIVE、STATIC 和 clarity refresh，多于六个预定操作。额外切换来自实验 marker、截图和 Chrome compositor 的真实可见更新。由于 detector 将所有可见变化视为 activity，这些事件均按正常活动处理。所有 clarity refresh 均成功，失败数为 0。

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

final-code H1 的第六个 sequence 接收 E2E 为 473.6 ms，其余五段为 104.8～308.6 ms；同一 sequence 的 sender detector 耗时为 24.8 ms。该尖峰发生在接收侧，不改变 detector 的上线判断。

两轮 sender 实际输出均为 `video/H265`，VideoToolbox encoder 为 `com.apple.videotoolbox.videoencoder.ave.hevc`，网络路径为 relay/relay UDP。Telemetry 同时记录了 H.265 的 33/39 QP、keyframe 和 encoder session，能够确认实际编码路径与参数应用结果。

## 原图检查

七个正式 run 的 sender 与 Android initial、fast-scroll、slow-scroll、typed、cursor、final 均以原始分辨率检查，共 84 张图；final-code H1 另检查 6 张 Chrome fixture、7 张 sender capture 和 7 张 Android decoded 图。总计 104 张。

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

原始 evidence 保持 Git ignored，未随报告发布。其中可能包含本机绝对路径、emulator/ADB 运行细节、菜单栏或 Dock 等本地环境信息。两次在锁屏状态启动的无效 H.265 run 已从 workspace 移入废纸篓，不计入结果。

发布的八张 PNG 均从固定文档的 Android decoded/output frame 重新编码。metadata 不含作者、creator 或来源 URL；画面只包含开源文档、测试 marker、测试输入和黑色 letterbox，不包含用户名、邮箱、路径、凭据、设备标识、pairing code、私有网络地址或无关桌面内容。

配置 secret scanner 已检查正式结果目录、final-code 结果目录和 tracked diff，未发现配置中的 TURN username/password。

## 上线后的观察项

- 关注多个连续操作的 ACTIVE latency p95、VideoToolbox drop、render freeze 和 encoder session rebuild。仅出现在单一 sequence、且发送端 detector 正常的延迟尖峰不触发回滚。
- 如果接收侧延迟在多个 sequence、多个 run 中持续增加，单独分析 transport 和 decoder，不向 detector 增加中间状态或更多阈值。
- 当前 render-gap window 从 marker 更新开始，而滚动 workload 会在 marker 后主动等待 500 ms。若未来继续使用 500 ms 绝对门槛，应先把测量起点移到真实滚动或输入开始时。
- 本次不改变 H.264/H.265 默认 codec policy，也不继续扩展 QP 或 VideoToolbox feature flags。
