import SwiftUI

struct StartView: View {
    @ObservedObject var coordinator: SessionCoordinator
    @State private var isStarting = false

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            VStack(alignment: .leading, spacing: 5) {
                Text("WebRTC 投屏").font(.largeTitle).fontWeight(.semibold)
                Text("选择本机在这次投屏中的角色")
                    .foregroundStyle(.secondary)
            }

            Picker("角色", selection: $coordinator.selectedRole) {
                Text("接收并播放").tag(CastingRole.receiver)
                Text("采集并发送").tag(CastingRole.sender)
            }
            .pickerStyle(.segmented)

            Form {
                TextField("信令地址", text: $coordinator.signalingURLText)
                    .textFieldStyle(.roundedBorder)

                Picker("连接模式", selection: $coordinator.selectedProfile) {
                    Text("TURN / UDP").tag(ICEProfile.productionRelay)
                    Text("Direct UDP（开发基线）").tag(ICEProfile.directBaseline)
                }

                if coordinator.selectedRole == .sender {
                    TextField("8 位配对码", text: $coordinator.senderPairingCode)
                        .textFieldStyle(.roundedBorder)
                    Picker("投屏来源", selection: $coordinator.selectedSource) {
                        Text("复制主屏幕").tag(CaptureSourceKind.mainDisplayMirror)
                        Text("扩展屏幕 · 1920 × 1080").tag(CaptureSourceKind.virtualExtendedDisplay)
                    }
                }
            }
            .formStyle(.grouped)

            if case .failed(let failure) = coordinator.state {
                Label(failure.message, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack {
                Spacer()
                Button(coordinator.selectedRole == .receiver ? "开始接收" : "开始投屏") {
                    isStarting = true
                    Task {
                        defer { isStarting = false }
                        try? await coordinator.start()
                    }
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .disabled(isStarting || (coordinator.selectedRole == .sender && coordinator.senderPairingCode.isEmpty))
            }
        }
        .padding(36)
        .frame(width: 610)
        .frame(minHeight: 510)
    }
}
