# Android TV reference Receiver 使用 Java 与 Views

Android TV Receiver 采用 Java 和 classic Android Views/XML，而不使用官方当前推荐的 Kotlin + Compose for TV。该应用的主要价值是展示 M150 Java AAR、`SurfaceViewRenderer`、signaling、PeerConnection 与 metrics 的最短可读集成路径；直接使用 View 可避免 Compose `AndroidView` bridge、额外 state/lifecycle 层和 Kotlin/Compose toolchain，同时仍必须完整满足 TV-only manifest、D-pad/focus、10-foot UI 与生命周期规范。下游生产应用可以在保留这些 WebRTC 边界的前提下改用 Kotlin/Compose。
