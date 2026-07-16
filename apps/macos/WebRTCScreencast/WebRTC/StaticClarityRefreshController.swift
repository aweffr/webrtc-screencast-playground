import Foundation

struct StaticClarityRefreshSnapshot: Equatable, Sendable {
    let mode: VisualStabilityMode
    let successfulRefreshes: UInt64
    let failedRefreshes: UInt64
    let motionRestores: UInt64
}

/// Applies the rare live encoder transition used to refresh a stable desktop.
/// The capture queue serializes transitions; the lock only protects metrics reads.
final class StaticClarityRefreshController: @unchecked Sendable {
    typealias ApplyLivePolicy = (_ maxFPS: Int, _ maxBitrateBps: Int) -> Bool
    typealias ForceKeyFrame = () -> Bool

    private let motionFPS: Int
    private let clarityFPS: Int
    private let maxBitrateBps: Int
    private let applyLivePolicy: ApplyLivePolicy
    private let forceKeyFrame: ForceKeyFrame
    private let lock = NSLock()
    private var mode: VisualStabilityMode = .motion
    private var successfulRefreshes: UInt64 = 0
    private var failedRefreshes: UInt64 = 0
    private var motionRestores: UInt64 = 0

    init(
        motionFPS: Int,
        clarityFPS: Int,
        maxBitrateBps: Int,
        applyLivePolicy: @escaping ApplyLivePolicy,
        forceKeyFrame: @escaping ForceKeyFrame
    ) {
        self.motionFPS = motionFPS
        self.clarityFPS = clarityFPS
        self.maxBitrateBps = maxBitrateBps
        self.applyLivePolicy = applyLivePolicy
        self.forceKeyFrame = forceKeyFrame
    }

    @discardableResult
    func handle(_ transition: VisualStabilityTransition) -> Bool {
        switch transition {
        case .none:
            return true
        case .enterStaticClarity:
            return enterStaticClarity()
        case .exitStaticClarity:
            return restoreMotionPolicy()
        }
    }

    func snapshot() -> StaticClarityRefreshSnapshot {
        lock.withLock {
            StaticClarityRefreshSnapshot(
                mode: mode,
                successfulRefreshes: successfulRefreshes,
                failedRefreshes: failedRefreshes,
                motionRestores: motionRestores
            )
        }
    }

    private func enterStaticClarity() -> Bool {
        guard snapshot().mode != .staticClarity else { return true }
        guard applyLivePolicy(clarityFPS, maxBitrateBps) else {
            lock.withLock { failedRefreshes += 1 }
            return false
        }
        guard forceKeyFrame() else {
            _ = applyLivePolicy(motionFPS, maxBitrateBps)
            lock.withLock {
                mode = .motion
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

    private func restoreMotionPolicy() -> Bool {
        guard snapshot().mode == .staticClarity else { return true }
        guard applyLivePolicy(motionFPS, maxBitrateBps) else {
            lock.withLock { failedRefreshes += 1 }
            return false
        }
        lock.withLock {
            mode = .motion
            motionRestores += 1
        }
        return true
    }
}
