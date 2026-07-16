import SwiftUI

struct SenderView: View {
    @ObservedObject var coordinator: SessionCoordinator

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("正在投屏").font(.title).fontWeight(.semibold)
                    Text(sourceName).foregroundStyle(.secondary)
                }
                Spacer()
                Button("导出诊断") { Task { await coordinator.exportDiagnostics() } }
                Button("停止投屏", role: .destructive) { Task { await coordinator.stop() } }
            }

            SessionStatusView(
                state: coordinator.state,
                profile: coordinator.selectedProfile,
                path: coordinator.metrics.selectedPath
            )
            MetricsSummaryView(metrics: coordinator.metrics)

            Spacer()
            if let directory = coordinator.sessionDirectory {
                Text("诊断记录：\(directory.path)").font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
            }
            if let message = coordinator.exportMessage {
                Text(message).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
            }
        }
        .padding(28)
        .frame(minWidth: 760, minHeight: 360)
    }

    private var sourceName: String {
        coordinator.selectedSource == .mainDisplayMirror ? "复制主屏幕" : "扩展屏幕 · 1920 × 1080"
    }
}
