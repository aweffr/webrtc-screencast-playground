# 项目关系

WebRTC 投屏交付链：

- `../webrtc-source-snapshots`：发布固定 WebRTC M150 源码及平台依赖的不可变快照，不含项目补丁和构建产物。
- `../my-webrtc-builds`：基于快照应用 CastTuning、codec 等改动，编译并发布 XCFramework、AAR 等二进制。
- 本项目：消费上述二进制，实现和验证 macOS 到 Android TV 的低延迟投屏，不直接修改或构建 WebRTC。

依赖方向为 `webrtc-source-snapshots` → `my-webrtc-builds` → 本项目。实验产生的底层需求可反馈给 `my-webrtc-builds`；源码同步归前者，WebRTC patches、构建和发布归中者，应用与端到端验证归本项目。

## 经验教训

### 跨平台 patch 边界与验证

修改多个平台共用的 patch 时，必须保证 patch 中修改的每个文件都存在于所有使用它的平台源码中。只属于 macOS、Android、iOS 或 Windows 的修改，应放在独立的平台 patch 中，并且只应用于对应平台。修改完成后，必须在每个受影响平台的 source snapshot 上检查完整 patch chain 能否成功应用；只验证部分文件或只验证一个平台不算完成。
