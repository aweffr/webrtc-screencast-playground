import SwiftUI

struct ReceiverView: View {
    @ObservedObject var coordinator: SessionCoordinator

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("接收投屏").font(.title).fontWeight(.semibold)
                    if let code = coordinator.pairingCode {
                        HStack(spacing: 8) {
                            Text("配对码")
                            Text(code)
                                .font(.system(.title2, design: .monospaced, weight: .semibold))
                                .textSelection(.enabled)
                        }
                    } else {
                        Text("正在获取配对码…").foregroundStyle(.secondary)
                    }
                }
                Spacer()
                Button("导出诊断") { Task { await coordinator.exportDiagnostics() } }
                Button("停止接收", role: .destructive) { Task { await coordinator.stop() } }
            }

            SessionStatusView(
                state: coordinator.state,
                profile: coordinator.selectedProfile,
                path: coordinator.metrics.selectedPath
            )

            MetalVideoView(store: coordinator.videoViewStore)
                .aspectRatio(16 / 9, contentMode: .fit)
                .background(Color.black)
                .clipShape(RoundedRectangle(cornerRadius: 10))
                .overlay {
                    if case .connected = coordinator.state {} else {
                        Text("等待发送端画面").foregroundStyle(.white.opacity(0.65))
                    }
                }

            MetricsSummaryView(metrics: coordinator.metrics)
            if let message = coordinator.exportMessage {
                Text(message).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
            }
        }
        .padding(24)
        .frame(minWidth: 880, minHeight: 700)
    }
}
