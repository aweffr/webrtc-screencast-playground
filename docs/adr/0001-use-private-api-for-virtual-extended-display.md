# 使用 private macOS API 创建虚拟扩展屏

客户端通过隔离的 provider 调用 private macOS `CGVirtualDisplay` API，自行创建虚拟扩展屏，使该模式不依赖物理显示器或另行安装的虚拟显示器产品。项目没有 Mac App Store 分发要求，接受直接分发和 macOS 升级兼容风险；virtual-display creation 不可用时，保留采集已有 display 的 fallback。
