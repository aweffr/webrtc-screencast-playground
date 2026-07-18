import Foundation
import ScreenCaptureKit

enum ContentActivityMode: String, Equatable, Sendable {
    case active
    case staticClarity = "static_clarity"
}

enum ContentActivityTransition: Equatable, Sendable {
    case none
    case enterStaticClarity
    case exitStaticClarity
}

struct DamageIdleDecision: Equatable, Sendable {
    let mode: ContentActivityMode
    let transition: ContentActivityTransition
    let lastDamageMonotonicNs: UInt64?
    let quietDeadlineMonotonicNs: UInt64?
    let nextQuietDeadlineMonotonicNs: UInt64?
}

struct DamageIdleDetector: Sendable {
    private let quietDurationNs: UInt64
    private var generation: UInt64 = 0
    private var lastObservationMonotonicNs: UInt64?
    private var lastDamageMonotonicNs: UInt64?
    private var quietDeadlineMonotonicNs: UInt64?
    private(set) var mode: ContentActivityMode = .active

    init(quietDurationNs: UInt64 = 600_000_000) {
        self.quietDurationNs = quietDurationNs
    }

    mutating func start() -> UInt64 {
        generation += 1
        lastObservationMonotonicNs = nil
        lastDamageMonotonicNs = nil
        quietDeadlineMonotonicNs = nil
        mode = .active
        return generation
    }

    mutating func stop() {
        generation += 1
        lastObservationMonotonicNs = nil
        lastDamageMonotonicNs = nil
        quietDeadlineMonotonicNs = nil
        mode = .active
    }

    mutating func observeDamage(at monotonicNs: UInt64) -> DamageIdleDecision {
        if let lastObservationMonotonicNs,
           monotonicNs < lastObservationMonotonicNs {
            return decision(transition: .none)
        }
        lastObservationMonotonicNs = monotonicNs
        lastDamageMonotonicNs = monotonicNs
        quietDeadlineMonotonicNs = monotonicNs + quietDurationNs
        let transition: ContentActivityTransition = mode == .staticClarity
            ? .exitStaticClarity
            : .none
        mode = .active
        return decision(transition: transition)
    }

    mutating func settleIfDue(
        at monotonicNs: UInt64,
        generation expectedGeneration: UInt64
    ) -> DamageIdleDecision {
        guard expectedGeneration == generation else {
            return decision(transition: .none)
        }
        if let lastObservationMonotonicNs,
           monotonicNs < lastObservationMonotonicNs {
            return decision(transition: .none)
        }
        lastObservationMonotonicNs = monotonicNs
        guard mode == .active,
              let quietDeadlineMonotonicNs,
              monotonicNs >= quietDeadlineMonotonicNs
        else {
            return decision(transition: .none)
        }
        mode = .staticClarity
        return decision(transition: .enterStaticClarity)
    }

    private func decision(transition: ContentActivityTransition) -> DamageIdleDecision {
        DamageIdleDecision(
            mode: mode,
            transition: transition,
            lastDamageMonotonicNs: lastDamageMonotonicNs,
            quietDeadlineMonotonicNs: quietDeadlineMonotonicNs,
            nextQuietDeadlineMonotonicNs: mode == .active ? quietDeadlineMonotonicNs : nil
        )
    }
}

enum ScreenDamageClassifier {
    static func hasDamage(
        status: SCFrameStatus,
        dirtyRects: [CGRect]?,
        contentRect: CGRect
    ) -> Bool {
        guard status != .started, let dirtyRects else { return true }
        return dirtyRects.contains { !isSystemStatusStripRedraw($0, within: contentRect) }
    }

    private static func isSystemStatusStripRedraw(
        _ dirtyRect: CGRect,
        within contentRect: CGRect
    ) -> Bool {
        guard contentRect.width > 0, contentRect.height > 0 else { return false }
        // macOS periodically redraws its capture/status strip even when the
        // shared content is unchanged. ScreenCaptureKit reports that repaint
        // as a thin, nearly full-width dirty rect at the top of the content.
        let intersection = dirtyRect.intersection(contentRect)
        let maximumStatusStripHeight = max(48, contentRect.height * 0.04)
        return !intersection.isNull
            && intersection.minY <= contentRect.minY + 1
            && intersection.maxY <= contentRect.minY + maximumStatusStripHeight
            && intersection.width / contentRect.width >= 0.98
    }
}
