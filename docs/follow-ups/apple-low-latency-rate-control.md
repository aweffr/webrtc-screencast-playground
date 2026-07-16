# Apple low-latency rate control

## 状态

Follow-up；不阻塞一期 minimal 投屏闭环。

## 背景

当前 pinned M150 preview 已包含经过 availability check 的 opt-in
`kVTVideoEncoderSpecification_EnableLowLatencyRateControl` 支持，但本 reference app 的
schema 2 CastTuning 默认值明确为 `false`。一期数据因此只代表 VideoToolbox realtime、
关闭 frame reordering 与现有 bitrate/QP 设置，不代表 Apple low-latency rate-control 模式。

## 后续范围

1. 用现有显式 feature switch 开启 `kVTVideoEncoderSpecification_EnableLowLatencyRateControl`，并记录 requested/effective state。
2. 保留未启用该属性的现有行为作为 control group，确保可以用相同 app、内容 corpus、网络路径和配置做 A/B comparison。
3. 比较 encode time、QP、bitrate overshoot、frame drop、glass-to-glass latency、freeze 与兼容性，不只观察单一延迟数字。
4. 若属性不受当前 OS/hardware 支持，必须显式记录 effective state，不能静默把 requested state 当成已生效。

## 启动条件

一期已跑通 capture、H.264 encode、WebRTC transport、decode/render、signaling 与 observability 闭环，并保存至少一组可重复的 baseline 数据。
