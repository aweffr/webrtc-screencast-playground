# 项目关系

WebRTC 投屏交付链：

- `../webrtc-source-snapshots`：发布固定 WebRTC M150 源码及平台依赖的不可变快照，不含项目补丁和构建产物。
- `../my-webrtc-builds`：基于快照应用 CastTuning、codec 等改动，编译并发布 XCFramework、AAR 等二进制。
- 本项目：消费上述二进制，实现和验证 macOS 到 Android TV 的低延迟投屏，不直接修改或构建 WebRTC。

依赖方向为 `webrtc-source-snapshots` → `my-webrtc-builds` → 本项目。实验产生的底层需求可反馈给 `my-webrtc-builds`；源码同步归前者，WebRTC patches、构建和发布归中者，应用与端到端验证归本项目。
