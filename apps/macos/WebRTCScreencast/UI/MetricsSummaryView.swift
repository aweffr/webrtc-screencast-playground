import SwiftUI

struct MetricsSummaryView: View {
    let metrics: SessionMetricsSummary

    var body: some View {
        HStack(spacing: 24) {
            metric("码率", formatBitrate(metrics.bitrateBps))
            metric("帧率", format(metrics.framesPerSecond, suffix: " fps"))
            metric("平均 QP", format(metrics.averageQP, suffix: ""))
            metric("RTT", format(metrics.roundTripTimeMs, suffix: " ms"))
            metric("已渲染", "\(metrics.renderedFrames)")
        }
        .padding(14)
        .background(.quaternary.opacity(0.45), in: RoundedRectangle(cornerRadius: 10))
    }

    private func metric(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(label).font(.caption).foregroundStyle(.secondary)
            Text(value).font(.system(.body, design: .monospaced)).contentTransition(.numericText())
        }
        .frame(minWidth: 78, alignment: .leading)
    }

    private func format(_ value: Double?, suffix: String) -> String {
        value.map { String(format: "%.1f%@", $0, suffix) } ?? "—"
    }

    private func formatBitrate(_ value: Double?) -> String {
        value.map { String(format: "%.2f Mbps", $0 / 1_000_000) } ?? "—"
    }
}

struct SessionStatusView: View {
    let state: SessionState
    let profile: ICEProfile
    let path: SelectedPathEvidence

    var body: some View {
        HStack(spacing: 12) {
            Circle()
                .fill(statusColor)
                .frame(width: 9, height: 9)
            Text(statusText).fontWeight(.medium)
            Spacer()
            Text(profile == .productionRelay ? "TURN / UDP" : "Direct UDP · 开发基线")
                .foregroundStyle(.secondary)
            if path.status != .unknown {
                Label(path.status == .verified ? "路径已验证" : "路径异常",
                      systemImage: path.status == .verified ? "checkmark.shield" : "exclamationmark.triangle")
                    .foregroundStyle(path.status == .verified ? .green : .red)
            }
        }
    }

    private var statusText: String {
        switch state {
        case .idle: "未连接"
        case .connectingSignaling: "正在连接信令"
        case .waitingForPeer: "等待配对"
        case .negotiating: "正在协商"
        case .connected: "已连接"
        case .ending: "正在停止"
        case .failed(let failure): failure.message
        }
    }

    private var statusColor: Color {
        switch state {
        case .connected: .green
        case .failed: .red
        case .idle: .secondary
        default: .orange
        }
    }
}
