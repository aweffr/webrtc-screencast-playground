# Apple low-latency rate control

## 状态

Follow-up；不阻塞一期 minimal 投屏闭环。

## 背景

当前使用的 WebRTC M150 release 已把 VideoToolbox encoder 配置为实时模式、关闭 frame reordering，并设置 bitrate、data-rate、expected-frame-rate 与 max-QP 等参数，但没有设置 `kVTVideoEncoderSpecification_EnableLowLatencyRateControl`。该能力无法从现有 app-facing ObjC API 或 CastTuning 配置打开，需要修改 WebRTC encoder implementation 并重新构建 framework。

## 后续范围

1. 在 VideoToolbox H.264 encoder 创建路径中，以 availability check 和显式 feature switch 控制 `kVTVideoEncoderSpecification_EnableLowLatencyRateControl`。
2. 保留未启用该属性的现有行为作为 control group，确保可以用相同 app、内容 corpus、网络路径和配置做 A/B comparison。
3. 比较 encode time、QP、bitrate overshoot、frame drop、glass-to-glass latency、freeze 与兼容性，不只观察单一延迟数字。
4. 若属性不受当前 OS/hardware 支持，必须显式记录 effective state，不能静默把 requested state 当成已生效。

## 启动条件

一期已跑通 capture、H.264 encode、WebRTC transport、decode/render、signaling 与 observability 闭环，并保存至少一组可重复的 baseline 数据。
