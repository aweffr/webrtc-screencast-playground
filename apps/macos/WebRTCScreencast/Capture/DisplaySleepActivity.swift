import Foundation

@MainActor
final class DisplaySleepActivity {
    typealias BeginActivity = (ProcessInfo.ActivityOptions, String) -> NSObjectProtocol
    typealias EndActivity = (NSObjectProtocol) -> Void

    private let beginActivity: BeginActivity
    private let endActivity: EndActivity
    private var token: NSObjectProtocol?

    init(
        beginActivity: @escaping BeginActivity = { options, reason in
            ProcessInfo.processInfo.beginActivity(options: options, reason: reason)
        },
        endActivity: @escaping EndActivity = { token in
            ProcessInfo.processInfo.endActivity(token)
        }
    ) {
        self.beginActivity = beginActivity
        self.endActivity = endActivity
    }

    func start() {
        guard token == nil else { return }
        token = beginActivity(
            [.userInitiated, .idleSystemSleepDisabled, .idleDisplaySleepDisabled],
            "Active WebRTC screen casting session"
        )
    }

    func stop() {
        guard let token else { return }
        self.token = nil
        endActivity(token)
    }
}
