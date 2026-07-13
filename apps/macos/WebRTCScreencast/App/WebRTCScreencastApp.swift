import SwiftUI

@main
struct WebRTCScreencastApp: App {
    @StateObject private var coordinator: SessionCoordinator

    init() {
        let arguments = ProcessInfo.processInfo.arguments
        let options = try? LaunchOptions.parse(arguments)
        let configuration = try? RuntimeConfiguration.load(arguments: arguments)
        _coordinator = StateObject(wrappedValue: SessionCoordinator(
            configuration: configuration,
            launchOptions: options
        ))
    }

    var body: some Scene {
        WindowGroup {
            Group {
                if coordinator.isActive {
                    if coordinator.selectedRole == .receiver {
                        ReceiverView(coordinator: coordinator)
                    } else {
                        SenderView(coordinator: coordinator)
                    }
                } else {
                    StartView(coordinator: coordinator)
                }
            }
            .task { await coordinator.runLaunchOptionsIfNeeded() }
            .onReceive(NotificationCenter.default.publisher(for: NSApplication.willTerminateNotification)) { _ in
                Task { await coordinator.stop() }
            }
        }
        .windowResizability(.contentSize)
    }
}
