# 低延迟高清会议投屏 HEVC 实验设计

## 目标

本实验为 1080p 会议投屏选择一套可上线的发送策略：首帧快、滚动和输入延迟低、静态文档文字清晰，并且不以丢帧或长时间冻结换取局部画质。实验比较 H.264 与 H.265，也评估 VideoToolbox HEVC 的 Spatial AQ、Low Latency Rate Control 和 Frame Reordering，但不把单个编码参数的“最优值”当作业务目标。

Swift Sender 已支持 `h264-only`、`h265-only`、`prefer-h265` 和默认优先 H.264 四种策略。本实验不改变这些语义；只有 HEVC 明确改善清晰度、交互延迟或首帧且其余关键指标不退化时，才建议部署显式使用 `prefer-h265`。

## 已有能力与缺口

- 主屏 capture 已按视觉稳定性在 `STATIC` 与 `ACTIVE` 间切换：STATIC 为 1 fps、较低 MaxQP、强制 IDR；ACTIVE 为 15 fps、较高 MaxQP。
- H.264 与 H.265 都能通过 CastTuning 动态重建 VideoToolbox session 并应用 MaxQP；现有证据只证明属性能生效，没有形成 HEVC 业务 A/B 结论。
- HEVC 普通硬件 encoder 支持 Spatial AQ；Apple RTVC 不支持 Spatial AQ 和 MaxAllowedFrameQP。
- 当前 telemetry 有 requested/effective QP、最近帧 QP、关键帧 QP 与 session binding，但缺少逐状态 QP 分布和 VideoToolbox encoder drop counter。
- 旧静态 QP 实验的 `24/22/20/18` 产物是 H.264，不能作为 HEVC 结果。

## 已比较方案

### 大范围逐参数 sweep

分别对 QP、Spatial AQ、RTVC 和 B-frame 做全因子组合能够得到完整曲面，但运行规模迅速增长，而且大量组合违反 VideoToolbox 能力边界或没有产品价值。本实验不采用。

### 只测 VideoToolbox capability probe

capability probe 能证明属性支持和回读，却不能回答真实 Chrome 文档的首帧、滚动延迟、静态清晰度和反复 session replacement。它保留为构建验收，不作为业务实验。

### 固定会议场景、分阶段淘汰（采用）

所有普通编码 case 使用相同 Chrome 文档和真实 STATIC/ACTIVE 切换。先做参数对齐的 H.264/H.265 head-to-head，再比较两个有实时 HEVC 工程依据的动态 QP 策略，最后只对胜出的 HEVC 策略测试三个 feature flag。正常完成 18～19 个有效 run；全部 HEVC 失败时在 12 个 run 停止。

## 固定 Chrome 业务内容

Chrome 在主屏全屏渲染本地、离线、固定的 Kubernetes 中文 Deployment 文档：

- repository commit：`be897babb9149b808e2ab8ed5367e5d0651b3dca`
- source path：`content/zh-cn/docs/concepts/workloads/controllers/deployment.md`
- Git blob：`817964c16c50546a73820e762446ca3e126d67a3`
- source SHA-256：`04ad31b16459a5a6f4d56868967b9d35303d9b7e1ea20300bfc826082fc2292f`

准备脚本校验源哈希，去掉 front matter、Hugo shortcode 和远程资源，通过 GitHub Markdown API 一次性生成 HTML body，再与固定本地 CSS、来源说明和 marker overlay 组成 versioned self-contained fixture。正式实验只访问 localhost，不访问公网。

本机使用 Google Chrome `150.0.7871.125`、临时 profile、100% zoom、无扩展和全屏。版本在整批实验中必须一致。Playwright CLI 发送真实 mouse-wheel 输入：每次 12 个 60 px step、间隔 50 ms，共 720 CSS px；每隔 5 秒一次，共 6 次。每次实际 `scrollY` 必须等于预期值 ±1 px。

每个 run 在 Android 首帧后执行：

1. 文档静止 25 秒；
2. 25～55 秒执行六次固定滚动；
3. 停止滚动 20 秒，验证静态清晰度恢复；
4. 导出初始静态、中段滚动和最终静态三组 image evidence。

固定页面使用现有 CRC marker 关联 capture 与 Android render，marker ROI 不进入文字质量区域。实验使用主屏而不是虚拟屏，因为当前产品的 static-aware MaxQP 策略只作用于主屏。

## Content-aware 策略契约

首轮只保留现有两状态模型，不扩展四状态：

- `STATIC`：1 fps、`staticMaxQP`，进入时应用 live patch 并强制 IDR；
- `ACTIVE`：15 fps、`activeMaxQP`；输入、滚动、动画与恢复均使用该状态。

现有视觉阈值、600 ms 稳定窗口和 1/15 fps 均冻结。普通 case 有效性要求：初始阶段进入 STATIC；每次 scroll 后 500 ms 内进入 ACTIVE；scroll burst 结束后 2 秒内回到 STATIC；六次切换都有 requested/effective QP、generation、encoder session 和关键帧绑定。

RTVC 不支持动态 MaxQP。StaticClarity controller 的 QP 参数改为 optional：普通 H.264/H.265 继续切换 FPS 和 QP；RTVC 只切换 FPS。RTVC 是能力边界 case，不具备本轮上线资格。

## 策略矩阵

公共参数为 1920×1080、STATIC/ACTIVE 1/15 fps、400 Kbps/3 Mbps/5 Mbps、AverageBitRate、RealTime、禁止 frame reordering、MaxFrameDelayCount=1、production-relay UDP 与同一 Android emulator。

### 对齐基线

| ID | Codec | STATIC MaxQP | ACTIVE MaxQP |
|---|---|---:|---:|
| A0 | H.264 | 24 | 32 |
| A1 | H.265 | 24 | 32 |

A0/A1 各运行三次，隔离 codec 本身的影响。

### HEVC 动态策略

| ID | Codec | STATIC MaxQP | ACTIVE MaxQP |
|---|---|---:|---:|
| B0 | H.265 | 33 | 39 |
| B1 | H.265 | 30 | 39 |

B0/B1 各运行三次。39 来自实时 VideoToolbox H.265 screensharing 工程经验；33 相差 6 QP，30 是静态清晰度候选下界。本轮不自动扩展到 30 以下。

### 胜出策略 feature flags

| ID | 相对 HEVC winner 的唯一变化 |
|---|---|
| C0 | Spatial AQ=`DISABLE` |
| C1 | Frame Reordering=`true` |
| C2 | Apple Low Latency Rate Control=`true`，不请求 MaxQP/Spatial AQ |

C0/C1/C2 各运行两次。若最终 winner 是 C0/C1，再补一次确认；C2 只量化延迟能力边界。

## 指标与选择规则

相对 A0 的硬门槛：first rendered frame 退化不超过 100 ms；ACTIVE software E2E p95 退化不超过 10 ms；没有超过 500 ms 的无渲染区间；VideoToolbox drop ratio 不超过 1%；marker 有效率下降不超过 1 个百分点；bitrate 不突破 5 Mbps；六次滚动均正确触发状态往返。

STATIC text/fine-lines 不得同时出现 SSIM-Y 下降超过 0.002、PSNR-Y 下降超过 0.5 dB，以及 12/16 px 中英文或代码在人工检查中明显变糊。

先淘汰违反硬门槛的策略，再按最差静态文字样本、ACTIVE p95、首帧、drop/freeze、bitrate 顺序选择。差异小于 0.002 SSIM、0.5 dB PSNR 或 5 ms latency 时视为同档，选择数值更高、约束更弱的 staticMaxQP。

## Telemetry 与证据

`my-webrtc-builds` 在 VideoToolbox callback 中维护 key/delta QP histogram 以及 submitted/encoded/dropped counters，通过 CastTuning snapshot 暴露。Swift JSONL 同时记录 content state、QP generation、session binding 和状态切换计数。Analyzer 聚合首帧、software marker latency、freeze、drop、bitrate、状态切换与 image metrics。

所有正式 run 保存完整配置、artifact SHA、app commit、Chrome version、文档 source hash、scroll timeline、双方 JSONL 和三组 image evidence。图像指标之外，执行者必须亲自打开并检查每个正式 case 的初始静态、中段滚动与最终静态接收图；报告记录检查结论和发现，不用自动指标替代人工判断。

## 运行规模与停止条件

- 阶段一 A0/A1：6 个有效 run；
- 阶段二 B0/B1：6 个有效 run；
- 阶段三 C0/C1/C2：6 个有效 run；
- 必要时为最终 C0/C1 增加 1 个确认 run。

每个 case 最多重试一次，全局最多 4 次基础设施重试，总 attempt 上限 23。所有 HEVC 动态策略在前 12 个 run 后均失败则停止，不执行 feature flags。

## 非目标

- 实体 Android TV hardware decoder 或 optical glass-to-glass latency；
- 四状态 content model、输入控制、VBR、BaseFrameQP、HighQuality preset、Main444；
- 为实验新增设置 UI 或更改 `VideoCodecPolicy.default` 的语义；
- 因实验顺手重构无关 capture、signaling 或 Android UI。

