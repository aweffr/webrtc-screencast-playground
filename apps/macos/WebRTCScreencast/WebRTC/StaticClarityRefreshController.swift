import Foundation

struct StaticClarityRefreshSnapshot: Equatable, Sendable {
    let mode: ContentActivityMode
    let successfulRefreshes: UInt64
    let failedRefreshes: UInt64
    let activeRestores: UInt64
}

/// Applies the rare live encoder transition used to refresh a stable desktop.
/// The capture queue serializes transitions; the lock only protects metrics reads.
final class StaticClarityRefreshController: @unchecked Sendable {
    typealias ApplyLivePolicy = (_ maxFPS: Int, _ maxBitrateBps: Int, _ maxQp: Int?) -> Bool
    typealias ForceKeyFrame = () -> Bool

    private let activeFPS: Int
    private let clarityFPS: Int
    private let maxBitrateBps: Int
    private let activeMaxQp: Int?
    private let staticMaxQp: Int?
    private let applyLivePolicy: ApplyLivePolicy
    private let forceKeyFrame: ForceKeyFrame
    private let lock = NSLock()
    private var mode: ContentActivityMode = .active
    private var successfulRefreshes: UInt64 = 0
    private var failedRefreshes: UInt64 = 0
    private var activeRestores: UInt64 = 0

    init(
        activeFPS: Int,
        clarityFPS: Int,
        maxBitrateBps: Int,
        activeMaxQp: Int?,
        staticMaxQp: Int?,
        applyLivePolicy: @escaping ApplyLivePolicy,
        forceKeyFrame: @escaping ForceKeyFrame
    ) {
        self.activeFPS = activeFPS
        self.clarityFPS = clarityFPS
        self.maxBitrateBps = maxBitrateBps
        self.activeMaxQp = activeMaxQp
        self.staticMaxQp = staticMaxQp
        self.applyLivePolicy = applyLivePolicy
        self.forceKeyFrame = forceKeyFrame
    }

    @discardableResult
    func handle(_ transition: ContentActivityTransition) -> Bool {
        switch transition {
        case .none:
            return true
        case .enterStaticClarity:
            return enterStaticClarity()
        case .exitStaticClarity:
            return restoreActivePolicy()
        }
    }

    func snapshot() -> StaticClarityRefreshSnapshot {
        lock.withLock {
            StaticClarityRefreshSnapshot(
                mode: mode,
                successfulRefreshes: successfulRefreshes,
                failedRefreshes: failedRefreshes,
                activeRestores: activeRestores
            )
        }
    }

    private func enterStaticClarity() -> Bool {
        guard snapshot().mode != .staticClarity else { return true }
        guard applyLivePolicy(clarityFPS, maxBitrateBps, staticMaxQp) else {
            lock.withLock { failedRefreshes += 1 }
            return false
        }
        guard forceKeyFrame() else {
            _ = applyLivePolicy(activeFPS, maxBitrateBps, activeMaxQp)
            lock.withLock {
                mode = .active
                failedRefreshes += 1
            }
            return false
        }
        lock.withLock {
            mode = .staticClarity
            successfulRefreshes += 1
        }
        return true
    }

    private func restoreActivePolicy() -> Bool {
        guard snapshot().mode == .staticClarity else { return true }
        guard applyLivePolicy(activeFPS, maxBitrateBps, activeMaxQp) else {
            lock.withLock { failedRefreshes += 1 }
            return false
        }
        lock.withLock {
            mode = .active
            activeRestores += 1
        }
        return true
    }
}
