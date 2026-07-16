import SwiftUI
import WebRTC

@MainActor
final class RemoteVideoViewStore: ObservableObject {
    let renderer = RTCMTLNSVideoView(frame: .zero)
}

struct MetalVideoView: NSViewRepresentable {
    @ObservedObject var store: RemoteVideoViewStore

    func makeNSView(context: Context) -> RTCMTLNSVideoView {
        return store.renderer
    }

    func updateNSView(_ nsView: RTCMTLNSVideoView, context: Context) {}
}
