import Foundation
import WebRTC

struct VideoRenderSnapshot: Equatable, Sendable {
    let framesRendered: UInt64
    let lastFrameTimestampNs: Int64?
    let width: Int32?
    let height: Int32?
}

final class MetricsVideoRenderer: NSObject, RTCVideoRenderer, @unchecked Sendable {
    private let lock = NSLock()
    private var framesRendered: UInt64 = 0
    private var lastFrameTimestampNs: Int64?
    private var size: CGSize = .zero

    func setSize(_ size: CGSize) {
        lock.withLock { self.size = size }
    }

    func renderFrame(_ frame: RTCVideoFrame?) {
        guard let frame else { return }
        lock.withLock {
            framesRendered += 1
            lastFrameTimestampNs = frame.timeStampNs
            size = CGSize(width: Int(frame.width), height: Int(frame.height))
        }
    }

    func snapshot() -> VideoRenderSnapshot {
        lock.withLock {
            VideoRenderSnapshot(
                framesRendered: framesRendered,
                lastFrameTimestampNs: lastFrameTimestampNs,
                width: size == .zero ? nil : Int32(size.width),
                height: size == .zero ? nil : Int32(size.height)
            )
        }
    }
}
