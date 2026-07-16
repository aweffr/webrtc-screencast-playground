# macOS 主屏幕静态 Max-QP 对比

本报告记录同一台 Mac 发送到 Android TV API 31 arm64 emulator、经 production TURN/UDP 的四档静态画质实验。所有 case 均保持 1920×1080、静态 1 fps、动态 15 fps、5 Mbps；只改变静态 `MaxAllowedFrameQP`。

- 生成时间：`2026-07-16T08:35:39Z`
- XCFramework SHA-256：`9b551376bfbd056b70d8b75142efa697a049fcff9a27f6a2a4694a847b140ba4`
- macOS app commit：`1aa5ae80d9e271339fa079a359848408d693621e`
- 发送端：`Mac17,8` / macOS `26.5.2`
- 接收端：`WebRTCScreencast_TV_API_31` / API `31` / `arm64-v8a`
- 单档运行时长：`30 s`
- 路径：`relay/relay + UDP`（每档均由现有 E2E verifier 校验）

## 数据

| 请求 Max QP | 回读 Max QP | 实际 IDR QP | IDR bytes | generation | applied/sample encoder session | VMAF（参考） |
|---:|---:|---:|---:|---:|---|---:|
| 24 | 24 | 24 | 93956 | 2 | `vt-0xa4d086e40-2` | 67.614 |
| 22 | 22 | 22 | 166650 | 6 | `vt-0xa01086800-6` | 65.404 |
| 20 | 20 | 20 | 214843 | 2 | `vt-0x929086800-2` | 65.160 |
| 18 | 18 | 18 | 198198 | 2 | `vt-0x9c505a800-2` | 68.292 |

VMAF 仅作为参考：每档 reference 是接收截图前后取得的本机主屏幕截图，按
ScreenCaptureKit 相同的 aspect-fit/letterbox 几何缩放到 1920×1080。它不是逐帧时间戳
对齐的严格视频 VMAF，而且四档抓到的桌面内容不同，因此分数不会随 QP 严格单调变化，
不能用于给四档画质排序，也不作为通过门槛。流中始终保留 cursor。

## Signaling 建链耗时

| 请求 Max QP | WebSocket connect (ms) | sender join → paired (ms) | offer → PeerConnection connected (ms) |
|---:|---:|---:|---:|
| 24 | 2.755 | 2.233 | 490.106 |
| 22 | 14.720 | 4.106 | 254.066 |
| 20 | 2.938 | 3.306 | 247.331 |
| 18 | 2.733 | 3.623 | 229.118 |

这些耗时来自 sender 的 monotonic event timestamps；只用于记录本轮 signaling/negotiation 建链，不代表 glass-to-glass latency。

## 视觉检查与结论

四张 Android 实收 PNG 均已按原始 1920×1080 分辨率通过 `view_image` 检查。主屏画面完整，
aspect-fit 与两侧 letterbox 正确；未见明显 macroblocking、破帧、色块或 Android receiver UI
覆盖。QP 24 的细小灰色文字相对柔和但可辨；QP 22 的密集中文正文已清晰；QP 20 与 QP 18
也保持清楚。由于每档采样时桌面内容不同，这里只确认各档达到可用画质，不把视觉结果解释成
严格 controlled A/B 排名。QP 18 图中的投屏状态窗和诊断路径属于被采集的 Mac 主屏内容，
不是接收端叠加。

本轮最关键的证据是四档均满足 `requested == effective == actual IDR QP`，并且每个 actual
QP sample 的 generation 与 encoder session 都和该次 apply 完全一致。这证明 motion 状态可继续
使用 Max QP 32，静止状态能在不重建 PeerConnection 的情况下切换到 24、22、20 或 18；底层
VideoToolbox compression session 会按 generation 受控替换，并在首帧前应用新上限。

建议默认静态 Max QP 采用 **22**：本轮密集中文在 QP 22 下已清晰，相比 20/18 给 5 Mbps
budget 与 IDR burst 留有更多余量。QP 20 可作为偏画质档；QP 18 暂不作为默认值。这个建议是
画质、瞬时 IDR 大小与稳定性的工程折中，不是由非严格对齐的 VMAF 排名推导出的门槛。

QP 18 首次运行在开始采集/编码前发生一次偶发 ICE failure；失败 run 未进入表格，保留在本机
`artifacts/static-max-qp/20260716T082859Z/qp-18/e2e-failed/`。表中的 QP 18 来自随后通过完整
production-relay verifier 的独立重跑。可复核的安全证据包括本目录的 `manifest.json`、每档
`qp-evidence.json`、VMAF JSON 与下列四张 Android 实收 PNG；完整原始 metrics 保留在本机
`artifacts/static-max-qp/20260716T082859Z/`。

## Android 实收画面

### Max QP 24

![Android received final frame — Max QP 24](2026-07-16-static-max-qp/qp-24-android-received-final.png)

### Max QP 22

![Android received final frame — Max QP 22](2026-07-16-static-max-qp/qp-22-android-received-final.png)

### Max QP 20

![Android received final frame — Max QP 20](2026-07-16-static-max-qp/qp-20-android-received-final.png)

### Max QP 18

![Android received final frame — Max QP 18](2026-07-16-static-max-qp/qp-18-android-received-final.png)
