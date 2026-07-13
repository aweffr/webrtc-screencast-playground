# Screencast

本上下文描述 macOS 设备向远端接收端传送桌面画面的核心业务概念，用于区分画面来源和会话语义。

## Language

**投屏会话（Casting Session）**:
一个发送端与一个接收端之间有明确开始和结束的连接，承载一路从发送端到接收端的桌面视频，以及双方的控制和测量消息。
_Avoid_: 会议、通话、双向投屏

**发送端（Sender）**:
投屏会话中选择画面来源并发布桌面视频的一方。同一会话中只有一个发送端。
_Avoid_: 主持人、主播、Caller

**接收端（Receiver）**:
投屏会话中接收、解码并播放桌面视频的一方。同一会话中只有一个接收端。
_Avoid_: 观众、被叫、Callee

**配对码（Pairing Code）**:
接收端申请并展示的一次性短期代码，发送端持有该代码即获得加入指定投屏会话的临时权限；成功配对后立即失效。它证明的是临时 capability，不代表用户身份。
_Avoid_: 房间号、会议号、固定密码

**信令服务（Signaling Service）**:
为发送端和接收端建立配对，并在双方之间转发会话协商消息的服务；它不生成或改写协商内容，也不传输媒体。
_Avoid_: SDP Server、WebRTC Server、媒体服务器

**直连基线（Direct Baseline）**:
仅用于单机开发对照的 ICE profile，允许 host/srflx direct UDP。它验证直连分支与 metrics 采集，不代表双机 LAN 性能，也不用于生产。
_Avoid_: 生产直连、LAN 性能基线

**生产中继（Production Relay）**:
生产路径使用的 ICE profile，设置 relay-only policy 且只配置 TURN/UDP；最终 selected candidate 必须证明媒体实际经过 relay。
_Avoid_: TURN fallback、TURN/TCP、自动路径选择

**主屏复制（Main Display Mirror）**:
采集当前主显示器的完整桌面，使接收端看到与发送端主显示器一致的画面，不改变发送端的桌面布局。输出完整保留主屏内容，并适配到 1920×1080 画布。
_Avoid_: 复制屏、主屏扩展

**虚拟扩展屏（Virtual Extended Display）**:
由客户端创建并由 macOS 视为独立桌面的 1920×1080、1× 显示区域；用户可以把窗口移动到该区域，接收端播放该区域的画面。
_Avoid_: 已有第二屏、外接屏采集、扩展屏
