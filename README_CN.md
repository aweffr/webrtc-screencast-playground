# WebRTC Screencast Playground

[English](README.md)

这是一个从原生 macOS Sender 向 Android TV Receiver 进行低延迟、单向 HEVC/H.264 桌面投屏的参考实现。项目使用一个小型 Go WebSocket 服务发放一次性配对码并转发 WebRTC 信令；媒体通过 ICE 直连传输，或经过配置的 TURN/UDP relay。

本仓库是便于理解和验证完整链路的示例，不是生产 SDK。链路保持清晰可查：ScreenCaptureKit → VideoToolbox/WebRTC M150 → UDP → Android WebRTC decoder → TV renderer。

## 项目提供什么

- **macOS app（Swift 6）：** GUI Sender、同一 app 的 CLI 启动模式、主屏复制，以及一个私有的 1920×1080 虚拟扩展屏。两种采集源都使用基于亮度的 static-clarity 模式；画面稳定时应用配置的 static max QP、请求新的 keyframe，并以约 1 fps 发送稳定画面。Sender 支持仅 H264、仅 H265、优先 H265 和默认优先 H264 四种策略。
- **Android TV app（兼容 Java 8 的源码）：** TV-only launcher、Receiver 优先注册、一次性配对码界面、HEVC 播放、适配 D-pad 操作的恢复流程，以及 app 私有 telemetry。
- **信令服务（Go）：** 提供 `/ws`、`/clock`、`/healthz` 和 Prometheus `/metrics`；不承载媒体或 TURN credentials。
- **网络 profile：** `direct-baseline` 用于本地对照，`production-relay` 强制使用 `relay/relay + UDP`。项目不支持 TURN/TCP。
- **可观测性：** 信令时序、时钟校准、capture/encode/decode/render 事件、标准化 RTCStats、selected path 验证、静态清晰度状态切换和 keyframe，以及脱敏 JSONL 诊断记录。
- **自动化证据：** 校准后的 software-marker 延迟，以及 1920×1080 截图、PSNR、SSIM、VMAF 参考值和 heatmap。这些指标不代表 optical glass-to-glass latency。

## 范围与限制

- 已验证的参考环境是一台 Apple Silicon Mac，以及配置为 1920×1080 的 API 31 arm64-v8a Android TV emulator。真实 TV 硬件仍待后续验证。
- 虚拟显示器使用私有的 `CGVirtualDisplay` compatibility declarations，不适合 App Store 分发。
- 始终采集鼠标指针。
- 全局键盘/鼠标转发、TURN/TCP、公开信令部署和 Apple `EnableLowLatencyRateControl` 不在首期范围内。
- 当前 macOS→Android 自动化链路显式使用 `h265-only`；未配置 `video_codec_policy` 时，Sender 默认优先 H264，并保留 H265 fallback。

## 仓库结构

```text
apps/macos/        SwiftUI macOS Sender 和旧版 macOS Receiver baseline
apps/android-tv/   Android TV Receiver 参考实现
server/            Go WebSocket 信令与时钟校准服务
config/            不含 secret 的 runtime 与 media-tuning 示例
scripts/           Bootstrap、验证、E2E、证据采集和分析工具
baselines/         纳入版本管理的汇总报告；原始截图和 metrics 不纳入版本管理
deploy/k3s/        信令服务的 Kubernetes manifest 示例
docs/              架构决策、研究、runbook、plan 和 follow-up
```

## 环境要求

- 运行 macOS 14 或更新版本的 Apple Silicon Mac
- Xcode 和 [XcodeGen](https://github.com/yonaskolb/XcodeGen)
- Go 1.24+
- 用于 Gradle/AGP 的 JDK 17（打包的 M150 AAR 仍兼容 Java 8 classfile）
- Android SDK command-line tools 和 emulator
- `jq`、`curl`、Python 3，以及带 `libvmaf` 的 FFmpeg，用于定量 baseline

## Bootstrap 与验证

Bootstrap 会校验由 [`aweffr/my-webrtc-builds`](https://github.com/aweffr/my-webrtc-builds) 生成的固定版本 M150 macOS arm64 archive 和 Android AAR，并仅安装到不纳入版本管理的本地依赖目录。

如需使用本地构建的实验产物，将 `WEBRTC_MACOS_TAR_GZ` 设置为 macOS arm64 tar 文件的绝对路径。bootstrap 仍会验证固定 checksum、arm64 framework 结构和 Android AAR。

```bash
git clone https://github.com/aweffr/webrtc-screencast-playground.git
cd webrtc-screencast-playground

./scripts/bootstrap-webrtc.sh
make verify
```

`make verify` 会运行 Go race tests、macOS tests/build、Android unit/lint/two-flavor builds、脚本与分析测试、产物检查和 `git diff --check`。

## 运行参考链路

### 1. 启动信令服务

```bash
./scripts/run-local-signaling.sh
```

### 2. 配置并启动 Android TV

首次使用时创建已验证的 emulator：

```bash
./scripts/provision-android-tv-avd.sh
```

Direct UDP 使用已提交的默认地址 `ws://10.0.2.2:8080/ws`。使用 TURN/UDP 时，把不含 credentials 的示例复制到 ignored debug resource 路径，并替换 placeholder：

```bash
mkdir -p apps/android-tv/app/src/debug/res/values
cp apps/android-tv/app/reference_runtime.local.xml.example \
  apps/android-tv/app/src/debug/res/values/reference_runtime.local.xml
```

构建并安装对应 flavor：

```bash
export JAVA_HOME=$(/usr/libexec/java_home -v 17)
./apps/android-tv/gradlew -p apps/android-tv installDirectBaselineDebug
```

打开 TV app 后，Receiver 会完成注册并显示八位配对码。

### 3. 启动 macOS Sender

完成一次构建，并为生成的 app 授予屏幕录制权限。之后可以使用 GUI，也可以通过 CLI 启动同一个 app executable：

```bash
make build-macos

APP="$PWD/DerivedData/Build/Products/Debug/WebRTCScreencast.app/Contents/MacOS/WebRTCScreencast"
"$APP" \
  --role sender \
  --profile direct-baseline \
  --pairing-code AB12-CD34 \
  --source main
```

`--source main` 采集完整主显示器，不改变 Mac 桌面布局。输出画布固定为 1920×1080；源画面不是 16:9 时，ScreenCaptureKit 会等比例缩放并居中，使用黑色背景补齐左右或上下区域，形成 pillarbox 或 letterbox，不拉伸或裁剪桌面内容。使用 `--source virtual` 可采集 app 管理的 1920×1080 虚拟扩展屏。使用 `--profile production-relay --config /absolute/path/to/runtime.json` 可强制通过 TURN/UDP 传输。

## Runtime 配置

不得提交本机 credentials。以 [`config/runtime.example.json`](config/runtime.example.json) 为起点，把填写后的文件保存在 ignored `secrets/` 目录中，并将文件权限设为 `0600`；TURN URL 需要显式指定：

```text
turn:turn.example.invalid:3478?transport=udp
```

客户端同时接受 `ws://` 和 `wss://`；本示例不强制使用 HTTPS/WSS。全部字段和本地 secret scan 说明见 [runtime configuration runbook](docs/runbooks/runtime-configuration.md)。

## Android TV 自动化 baseline

启动 emulator、准备 runtime config 并确认屏幕录制权限生效后，执行：

```bash
./scripts/run-android-tv-baseline.sh \
  --runtime-config "$PWD/secrets/runtime.json"
```

Runner 先执行四个功能 session（Direct/TURN × main/virtual），再执行三组交替进行、每组 80 秒的 Direct/TURN 虚拟屏 chart 测量。原始证据保存在 ignored `artifacts/android-tv-e2e/` 下；可安全提交的汇总报告保存在 `baselines/` 下。

当前单 Mac emulator baseline 汇总见 [`baselines/2026-07-15-3bc825c-android-tv.md`](baselines/2026-07-15-3bc825c-android-tv.md)：Direct software-marker E2E p50/p95 为 62.24/77.39 ms，强制 TURN/UDP 为 70.58/84.69 ms；capture-to-Android VMAF 参考值的中位数分别为 96.50 和 96.38。项目不依据这些测量结果设置性能 gate。

## 文档

请先阅读[文档索引](docs/README.md)。常用运维指南包括：

- [本地开发](docs/runbooks/local-development.md)
- [Android TV E2E](docs/runbooks/android-tv-e2e.md)
- [macOS 采集权限](docs/runbooks/macos-capture-permission.md)
- [信令服务](docs/runbooks/signaling-server.md)
- [架构术语](CONTEXT.md)

## 安全与诊断

Runtime credentials、已填写的 Android XML、下载的二进制、构建产物、原始截图和 session metrics 均不纳入版本管理。结构化 recorder 会对信令 payload 脱敏；自动化运行在成功前会扫描保留的输出，检查是否包含配置的 TURN 值或完整配对码。漏洞报告方式见 [SECURITY.md](SECURITY.md)。

## License

项目采用 [Apache License 2.0](LICENSE)。私有虚拟显示器 compatibility declarations 包含第三方 MIT-licensed 代码，详情见 [NOTICE](NOTICE)。
