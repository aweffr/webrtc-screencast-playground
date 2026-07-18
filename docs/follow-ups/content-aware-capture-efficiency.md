# Follow-up：降低静止画面的捕获成本

## 当前决定

当前保持 ScreenCaptureKit 最大 15 fps，由应用层 Frame Gate 决定哪些新画面进入 `RTCVideoSource`。复制主屏幕在视觉稳定 600 ms 后会把 WebRTC source/sender live limit 切到 1 fps 并请求一个 IDR，用于改善静止桌面的清晰度；这不是降低 ScreenCaptureKit 捕获成本，capture callback 仍保持原 cadence。

M150 源码中的 zero-hertz adapter 支持约每秒重发最后一帧，产品上可以接受这一行为；但当前 CastTuning ObjC 接入只把 `max_fps` 传给 `RTCVideoSource.adaptOutputFormat`，没有把 `min_fps=0` 写入 source constraints。安全过滤后的实际运行日志因此显示 `Zero hertz mode disabled`。后续若需要 idle RTP repeat，必须先补齐并验证这条 framework 接入，不能把“源码具备能力”写成“当前 app 已启用”。

一期不监听全局鼠标或键盘，不申请 Input Monitoring 或 Accessibility 权限，也不在静止后动态把 ScreenCaptureKit 降到 5 fps。静止清晰度模式只依赖 ScreenCaptureKit dirty rect；内容或 cursor 的任意可见 damage 都立即恢复 ACTIVE，连续 600 ms 无 damage 后进入 STATIC。

## 启动条件

完成首版基线测试后，只有观测数据表明固定 15 fps capture 在静止场景造成了需要处理的 CPU、GPU、内存带宽、温度或 energy impact，才启动本 follow-up。开始实现前应先固定测试设备、静止内容、运行时长和改进目标，避免仅凭活动监视器的单次读数引入额外权限与状态机。

## 候选改动

1. 静止持续 1–2 秒后，通过 `SCStream.updateConfiguration` 把 `minimumFrameInterval` 降到 5 fps；画面恢复活动时回到 15 fps。
2. 若低 cadence 的最坏唤醒延迟不可接受，再评估全局 mouse/scroll/key event 作为提前升档信号。
3. 保留 Frame Gate 作为主控制层，ScreenCaptureKit cadence 只用于降低长期捕获成本。

## 设计与验收事项

- 分别评估 mouse event 与 keyboard event 所需的系统权限，不把 Accessibility 当作默认前提。
- 用户拒绝授权时，系统应继续使用 fixed 15 fps capture + Frame Gate，不能阻断投屏。
- 记录 idle 降档耗时、输入到 15 fps 恢复耗时、输入到首个新提交帧耗时和误唤醒次数。
- 对比改动前后的 capture callback fps、submitted fps、CPU、GPU、energy impact 和端到端交互延迟。
- 状态切换不能在 ScreenCaptureKit callback 或 WebRTC media thread 上执行阻塞工作。

## 参考

- [Apple WWDC22: Take ScreenCaptureKit to the next level](https://developer.apple.com/videos/play/wwdc2022/10155/)
- [M150 frame cadence reference](https://github.com/aweffr/my-webrtc-builds/blob/main/references/M150/upstream/video/frame_cadence_adapter.cc)
- [可行性调研基线](../research/2026-07-13-feasibility-baseline.md)
