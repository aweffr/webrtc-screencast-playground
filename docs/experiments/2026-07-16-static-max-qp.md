# macOS 主屏幕静态 Max-QP 对比

本报告记录同一台 Mac 发送到 Android TV API 31 arm64 emulator、经 production TURN/UDP 的四档静态画质实验。所有 case 均保持 1920×1080、静态 1 fps、动态 15 fps、5 Mbps；只改变静态 `MaxAllowedFrameQP`。

- 生成时间：`2026-07-16T10:10:55Z`
- XCFramework SHA-256：`9b551376bfbd056b70d8b75142efa697a049fcff9a27f6a2a4694a847b140ba4`
- macOS app commit：`f90e985c8b0d4488fa2fb325192ee6a17f008176`
- 发送端：`Mac17,8` / macOS `26.5.2`
- 接收端：`WebRTCScreencast_TV_API_31` / API `31` / `arm64-v8a`
- 单档运行时长：`30 s`
- 路径：`relay/relay + UDP`（每档均由现有 E2E verifier 校验）
- 原始证据目录：`artifacts/static-max-qp/20260716T100706Z`

## 数据

| 请求 Max QP | 回读 Max QP | 实际 IDR QP | IDR bytes | generation | encoder session | metrics record | ICE path | Android 实收图 | `view_image` 观察 | VMAF（参考） |
|---:|---:|---:|---:|---:|---|---|---|---|---|---:|
| 24 | 24 | 24 | 106536 | 10 | `vt-0xc73d20c80-10` | 27 → 28 | relay/relay + UDP | [PNG](2026-07-16-static-max-qp/qp-24-android-received-final.png) | GitHub release 页整帧完整，小号 asset 文字可读，无色块/宏块 | 66.330 |
| 22 | 22 | 22 | 194350 | 2 | `vt-0x77bd1cc80-2` | 20 → 21 | relay/relay + UDP | [PNG](2026-07-16-static-max-qp/qp-22-android-received-final.png) | 中文正文、标题与细线清晰，cursor 可见，无色块/宏块 | 61.618 |
| 20 | 20 | 20 | 216603 | 2 | `vt-0xc42140c80-2` | 20 → 21 | relay/relay + UDP | [PNG](2026-07-16-static-max-qp/qp-20-android-received-final.png) | 中文正文、标题与细线清晰，无色块/宏块 | 62.978 |
| 18 | 18 | 18 | 236815 | 2 | `vt-0x859908c80-2` | 20 → 21 | relay/relay + UDP | [PNG](2026-07-16-static-max-qp/qp-18-android-received-final.png) | 中文正文、标题与细线清晰，无色块/宏块 | 63.506 |

VMAF 仅作为参考列：reference 是截图时间窗口内的本机主屏幕，按 ScreenCaptureKit 相同的 aspect-fit/letterbox 几何缩放到 1920×1080。它不是发送帧与接收帧逐像素时间戳对齐的严格视频 VMAF；四个 case 的页面内容和滚动位置也不完全相同（QP 24 是 GitHub release 页，其余为中文文档页）。因此 VMAF 不能用于四档的严格排名，也不作为通过门槛。

ScreenCaptureKit 的 `showsCursor` 始终开启；QP 22 截图中可直接看到 cursor，其他帧中是否可见取决于当时指针位置。

## 证据绑定

自动化不再从 metrics 历史中逆向寻找“仍然匹配请求 QP”的旧记录，而只接受当前最新的 `rtc_stats`。每个 case 必须同时满足：

- clarity mode 为 `static_clarity`，requested/effective Max QP 一致且 VideoToolbox 回读为 `applied`；
- QP sample generation 等于 Max-QP generation；
- QP sample encoder session 等于实际应用 Max-QP 的 encoder session；
- actual IDR QP 和 encoded bytes 均有效；
- Android 截图后必须等到一条更新的 1 Hz `rtc_stats`，且截图前后的 generation/session/QP/bytes 完全一致。

四档 evidence 均标记 `generation-session-stable-across-fresh-post-screenshot-sample`，并保存了表中的 before/after metrics record index。报告生成器会拒绝 after index 没有严格大于 before index 的证据。

## Signaling 建链耗时

| 请求 Max QP | WebSocket connect (ms) | sender join → paired (ms) | offer → PeerConnection connected (ms) |
|---:|---:|---:|---:|
| 24 | 18.142 | 4.154 | 217.166 |
| 22 | 3.073 | 1.993 | 253.122 |
| 20 | 3.532 | 2.861 | 224.458 |
| 18 | 12.988 | 3.139 | 208.828 |

这些耗时来自 sender 的 monotonic event timestamps；只用于记录本轮 signaling/negotiation 建链，不代表 glass-to-glass latency。

## Android 实收画面

以下四张 1920×1080 PNG 均已使用 `view_image`、原始分辨率逐张检查。画面均为 Android TV 实际 decode/render 后的最终帧；左右黑边是主屏幕 aspect-fit 到 16:9 后的正常 pillarbox，未发现接收端 UI 覆盖、视频破损、色块或明显宏块。

### Max QP 24

![Android received final frame — Max QP 24](2026-07-16-static-max-qp/qp-24-android-received-final.png)

### Max QP 22

![Android received final frame — Max QP 22](2026-07-16-static-max-qp/qp-22-android-received-final.png)

### Max QP 20

![Android received final frame — Max QP 20](2026-07-16-static-max-qp/qp-20-android-received-final.png)

### Max QP 18

![Android received final frame — Max QP 18](2026-07-16-static-max-qp/qp-18-android-received-final.png)

## 结论与建议

本轮证明了核心闭环：运行时传入 24/22/20/18 后，VideoToolbox 使用对应 encoder session，且与 Android 截图前后 fresh metrics sample 绑定的 IDR 上精确观测到 24/22/20/18。

由于 QP 24 的画面内容与其他三档不同，它的 `106536 bytes` 不能与其他三档直接做码率成本对比。QP 22/20/18 的中文文档画面较为接近，IDR 大小随 QP 收紧而增长：`194350 → 216603 → 236815 bytes`；三张图的文字均已清晰可读，本轮肉眼检查没有观察到 QP 18 相比 QP 22 足以抵消额外 IDR 成本的明显收益。

建议：

- 静态默认使用 **Max QP 22**：在本轮文字类桌面上已达到清晰可读，且在相近内容中的 IDR 体积低于 20/18。
- 对画质更偏执且能承受更大 IDR 的参考实现，可选 **Max QP 20**。
- **Max QP 18** 已验证能精确生效，但本轮不建议作为默认值。
- 画面恢复动态后继续放宽到 **Max QP 32**，不用静态策略牺牲动态时的码率容量。

这是一期参考实现的参数建议，不是通用画质门槛。
