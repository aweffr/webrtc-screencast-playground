# HEVC 会议投屏实验结果（2026-07-18）

## 结论

本轮不建议把会议投屏默认策略切到 HEVC，也不进入 Spatial AQ、Frame Reordering 和 Apple Low Latency Rate Control 的 feature stage。Swift sender 继续支持 `h264-only`、`h265-only`、`prefer-h265` 和默认优先 H.264 四种策略；生产默认保持优先 H.264。

三个 HEVC 基础候选都没有同时满足静态文档质量、动态响应和 content-aware 状态切换门槛。B0（STATIC/ACTIVE MaxQP 33/39）在 HEVC 中最接近业务目标，但它仍存在系统性的 Y-plane 质量下降，并且三次 run 的静态/动态状态往返不稳定。继续扩大 QP 或 feature flag 矩阵不能解决这两个基础问题。

## 正式实验与 provenance

- 结果目录：`artifacts/hevc-meeting/20260718T022620Z/`
- app commit：`5f24ad1f6e2a8eedb0b9523ffbdf7792facdbb2b`
- builder commit：`da7818a854bb5d227f306af9816d2b54ebc7a74e`
- macOS WebRTC artifact SHA-256：`74344a3ab08b49e445dc47258cb02e696a4a9b6eb04eb09d866552aefbdfabc7`
- Android WebRTC AAR SHA-256：`a85c2cb62dff0c48ec07cd33c10ddcdcb8a3ad650fd83e21ec489e8fe68a8674`
- 实际 macOS executable SHA-256：`ad74dd515688417d786331a37bdb321e4a70ff719d5c5497c04f53943b15c3c4`
- Chrome：`150.0.7871.129`
- 12/12 base run 有效，0 invalid，0 retry；每个 run 另存实际 Android APK SHA-256。

第一次正式启动被 Chrome exact-version gate 拒绝：本机 Chrome 已从 `150.0.7871.125` 自动更新到 `150.0.7871.129`。这两次 attempt 没有启动 E2E，也没有纳入上述结果。修正冻结版本并形成新的 clean commit 后，实验从全新目录重新开始。

固定内容为本地 Kubernetes 中文 Deployment 文档。每个 run 初始静止 20 秒，随后每隔 8 秒执行一次 12×60 px mouse-wheel burst，共六次，最后静止 20 秒；六次实际 `scrollY` 均精确为 720/1440/2160/2880/3600/4320 px。

## 聚合结果

| Case | 定位 | STATIC/ACTIVE MaxQP | 实际 key/delta QP p95（最大） | 首帧 ms | ACTIVE p95 ms | 最大 render gap ms | VT drop | 峰值 bitrate Mbps | 最差 SSIM-Y / PSNR-Y | 结论 |
|---|---|---:|---:|---:|---:|---:|---:|---:|---:|---|
| A0 | H.264 reference | 24/32 | 32/32（32） | 1493.2 | 231.5 | 463.0 | 0 | 5.61 | 0.9981 / 40.77 | 对照基线 |
| A1 | 对齐 H.265 | 24/32 | 32/32（32） | 1463.2 | 214.7 | 525.5 | 0 | 2.55 | 0.9758 / 35.54 | 不通过 |
| B0 | HEVC 弱约束 | 33/39 | 34/33（38） | 1337.0 | 217.6 | 493.7 | 0 | 3.40 | 0.9746 / 35.35 | 不通过 |
| B1 | HEVC 静态收紧 | 30/39 | 34/32（37） | 1384.2 | 245.4 | 594.8 | 0 | 3.29 | 0.9750 / 35.38 | 不通过 |

A0 是 reference，不代表当前 H.264 路径满足全部产品目标。它有一次 5.61 Mbps 的约一秒 WebRTC stats 峰值，而且 content-aware 状态机同样不稳定。

门禁结果：

- A1：一次 525.5 ms render gap、content-aware 往返失败、静态图像质量失败。
- B0：首帧、ACTIVE p95、drop 和 bitrate 通过；content-aware 往返与静态图像质量失败。本轮记录的 493.7 ms render gap 来自后来确认会漏算 ACTIVE 窗口首尾的旧 tracker，因此不足以证明 freeze 门槛通过。
- B1：ACTIVE p95 相对 A0 退化 14.0 ms，一次 594.8 ms render gap，content-aware 往返与静态图像质量失败。

B0/B1 的实际 QP 没有长期贴住 ACTIVE MaxQP 39：key/delta p95 约为 34/32～33，最大值 37～38。将 STATIC MaxQP 从 33 收紧到 30 没有产生可见或量化的静态质量收益，因此没有依据继续向更低 HEVC QP 扩展。

## Content-aware 结果

Analyzer 对每一次 scroll burst 分别要求：先观察到 ACTIVE MaxQP 已应用，再在下一次 burst 前观察到 STATIC MaxQP 已应用；两者都必须绑定 generation、encoder session、QP sample 和关键帧。总 transition counter 还必须恰好为 6，超过 6 视为 thrashing。

下列值为每个 run 的“完整绑定 burst 数 / transition counter”：

| Case | run-1 | run-2 | run-3 |
|---|---:|---:|---:|
| A0 | 2/3 | 6/7 | 0/7 |
| A1 | 1/5 | 6/7 | 2/6 |
| B0 | 6/7 | 0/5 | 5/6 |
| B1 | 6/7 | 0/2 | 3/5 |

没有一个 case 在三次 run 中都满足 6/6。8 秒固定间隔已经给静态回落留出比上一轮更多的观察时间，结果仍同时出现漏切换和多余切换；这说明当前瓶颈是 static-aware detector/settle/hysteresis 的稳定性，而不是再选择一个 MaxQP 数字。

## 人工截图检查

执行者用 `view_image(detail=original)` 逐张打开了 12 张 inspection sheet：每个 case 的 sender 全景、Android 全景和 Android 正文细节，覆盖三次 run 的初始、中段和最终阶段；另外对 B0 run-2 的 workload source 与 sender sequence-4 原图做了直接比较。

- 四个 case 的 12 px 中文、16 px 中英文混排、代码和 1 px 细线均可读，没有明显 block、ringing 或 ghosting。
- A0 Android 画面相对 sender 有轻微偏粉/偏暖底色。
- 三个 HEVC case 更亮，浅灰边框和小字号对比度更低；这与约 0.975 的最差 SSIM-Y 和约 35.4 dB 的最差 PSNR-Y 一致。该差异更像 HEVC 编解码链路的 luma/color-range 问题，不能归因于某个 MaxQP 上限。
- B0 与 B1 肉眼差异很小，不支持以更严格的 STATIC MaxQP 换取额外约束。
- B0 run-1 初始样本包含瞬时 macOS menu bar/Dock overlay，正文仍清楚，sender/Android 两侧均包含该内容；B0 的最差静态指标来自最终样本，因此该 overlay 没有决定 B0 的质量失败结论。

## 测量限制

B0 run-2 的 workload `middle-scroll.png` 已到固定 `scrollY=2160` 内容位置，但 sender `sequence-4` 图仍是更早的正文位置。这证明 fixed overlay marker 可以先于正文 compositor update 被捕获。Marker sequence delivery 为 6/6，但 ACTIVE marker p95 只能作为方向性指标，不能单独代表正文滚动完全呈现的延迟。

完成审计还发现，本轮 Android ACTIVE gap tracker 从首个新 sequence frame 才开始计时，并且没有把最后一帧到一秒窗口末尾的间隔计入最大 gap。因此表中的 render gap 是已观察到的内部间隔，A1/B1 超过 500 ms 仍是有效失败证据，但 B0 低于 500 ms 不能作为完整的通过证明。后续实现已补上窗口首尾 gap，并增加回归测试；正式结果不使用新实现追溯改写。

本轮停止结论不依赖上述限制：B0 即使不判断 ACTIVE latency 和 freeze，仍违反静态质量和 content-aware 门槛；A1/B1 还有独立的质量或状态失败。

## 下一步（保持收敛）

1. 先校正 HEVC sender→Android 链路的 luma/color-range 一致性，用同一静态 fixture 验证浅灰边框和 Y-plane 指标。
2. 修正现有 static-aware detector/settle/hysteresis，使六次固定 burst 在三次重复中都恰好完成 ACTIVE→STATIC 往返，并保留逐 burst QP/session/keyframe binding。
3. 将 latency marker 绑定到实际滚动正文内容，或在正文 ROI 上增加内容到达证据。
4. 只重跑 A0/A1/B0/B1 base；只有 HEVC 基础候选过门禁后，才运行 C0/C1/C2。

当前没有业务价值支持继续测试更多 QP、preset、VBR、Main444 或 ROI 组合。
