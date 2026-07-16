# macOS 主屏幕静态 Max-QP 对比

本报告记录同一台 Mac 发送到 Android TV API 31 arm64 emulator、经 production TURN/UDP
的四档静态画质实验。所有 case 均保持 1920×1080、静态 1 fps、动态 15 fps、5 Mbps；
只改变静态 `MaxAllowedFrameQP`。

- 生成时间：`2026-07-16T06:41:13Z`
- XCFramework SHA-256：`264692ea18790940a1121ca4d2a0729722fbd604e3fc88f2812b1541a91a8044`
- macOS app commit：`a2c306e4dac27a9792a640b2920ed990a0f632cd`
- 发送端：`Mac17,8` / macOS `26.5.2`
- 接收端：`WebRTCScreencast_TV_API_31` / API `31` / `arm64-v8a`
- 单档运行时长：`30 s`
- 路径：`relay/relay + UDP`（每档均由现有 E2E verifier 校验）

## 数据

| 请求 Max QP | 回读 Max QP | 实际 IDR QP | IDR bytes | generation | encoder session | VMAF（参考） |
|---:|---:|---:|---:|---:|---|---:|
| 24 | 24 | 24 | 111619 | 14 | `vt-0x93cc6a6c0-14` | 63.817 |
| 22 | 22 | 22 | 125838 | 4 | `vt-0xba2c6a6c0-4` | 64.261 |
| 20 | 20 | 20 | 137333 | 6 | `vt-0xb4cc6a6c0-6` | 55.924 |
| 18 | 18 | 18 | 111486 | 2 | `vt-0x88cc6a6c0-2` | 65.788 |

VMAF 仅作为参考：reference 是接收截图前后取得的本机主屏幕截图，按 ScreenCaptureKit
相同的 aspect-fit/letterbox 几何缩放到 1920×1080。四组抓到的页面内容与时刻不同，
并非严格逐帧对齐的 controlled A/B，因此分数不随 QP 单调变化，不能据此判断 QP 20
差于 QP 24，也不作为通过门槛。流中始终保留 cursor。

## Signaling 建链耗时

| 请求 Max QP | WebSocket connect (ms) | sender join → paired (ms) | offer → PeerConnection connected (ms) |
|---:|---:|---:|---:|
| 24 | 3.837 | 2.291 | 181.013 |
| 22 | 3.412 | 3.126 | 233.698 |
| 20 | 13.763 | 3.682 | 205.990 |
| 18 | 2.720 | 2.807 | 206.809 |

这些耗时来自 sender 的 monotonic event timestamps；只用于记录本轮 signaling/negotiation
建链，不代表 glass-to-glass latency。

## 视觉检查与结论

四张 1920×1080 Android 实收 PNG 均已按原尺寸人工检查：主屏完整、aspect ratio 正确、
cursor 保留，中文与 Latin 小字可辨，没有发现明显 macroblocking、色块或覆盖 Android UI。
QP 18 画面右侧的灰色短横线是发送端网页的 loading animation，并非 codec artifact。

本轮最重要的结论不是 VMAF 高低，而是四档均证明了 `requested == effective == actual IDR QP`。
也就是说，动态状态可以继续使用 motion Max QP 32，静态状态确实能在不重建
PeerConnection 的前提下切换到 24、22、20 或 18；底层 VideoToolbox compression session
会按 generation 受控替换，并在首帧前应用新上限。

建议默认静态 Max QP 从 24 收紧到 **22**：本轮密集中文/英文文字在 QP 22 下已经清楚，
相对 20/18 给 5 Mbps budget 和 IDR burst 留有更多余量。QP 20 可作为机器本地的偏画质档；
QP 18 暂不作为默认值。由于四组不是同画面 controlled A/B，这个建议是工程折中，不是由
本轮 VMAF 排名推导出的画质门槛。

可复核的安全证据包括 [manifest](2026-07-16-static-max-qp/manifest.json)、每档
`qp-evidence.json`、VMAF JSON 和下面四张 Android 实收 PNG。完整原始 signaling、sender、
receiver metrics 保留在本机 ignored artifact root
`artifacts/static-max-qp/20260716T063731Z/`。

## Android 实收画面

### Max QP 24

![Android received final frame — Max QP 24](2026-07-16-static-max-qp/qp-24-android-received-final.png)

### Max QP 22

![Android received final frame — Max QP 22](2026-07-16-static-max-qp/qp-22-android-received-final.png)

### Max QP 20

![Android received final frame — Max QP 20](2026-07-16-static-max-qp/qp-20-android-received-final.png)

### Max QP 18

![Android received final frame — Max QP 18](2026-07-16-static-max-qp/qp-18-android-received-final.png)
