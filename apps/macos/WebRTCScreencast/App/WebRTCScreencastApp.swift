import SwiftUI

@main
struct WebRTCScreencastApp: App {
    @StateObject private var coordinator: SessionCoordinator

    init() {
        let arguments = ProcessInfo.processInfo.arguments
        var options: LaunchOptions?
        var startupFailure: String?
        do {
            options = try LaunchOptions.parse(arguments)
        } catch {
            startupFailure = error.localizedDescription
        }
        let explicitConfiguration = arguments.contains("--config")
        var configuration: RuntimeConfiguration?
        do {
            configuration = try RuntimeConfiguration.load(arguments: arguments)
        } catch {
            if explicitConfiguration, startupFailure == nil { startupFailure = error.localizedDescription }
        }
        _coordinator = StateObject(wrappedValue: SessionCoordinator(
            configuration: configuration,
            launchOptions: options,
            startupFailure: startupFailure
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
