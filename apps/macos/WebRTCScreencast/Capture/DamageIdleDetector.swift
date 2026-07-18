import CoreVideo
import Darwin
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
        contentRect: CGRect,
        statusStripPixelsChanged: (CGRect) -> Bool = { _ in true }
    ) -> Bool {
        guard status != .started, let dirtyRects else { return true }
        return dirtyRects.contains {
            !isSystemStatusStripCandidate($0, within: contentRect)
                || statusStripPixelsChanged($0)
        }
    }

    private static func isSystemStatusStripCandidate(
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

enum NV12PixelBufferComparator {
    static func hasChanges(
        between previous: CVPixelBuffer?,
        and current: CVPixelBuffer
    ) -> Bool {
        guard let previous,
              previous !== current,
              CVPixelBufferGetWidth(previous) == CVPixelBufferGetWidth(current),
              CVPixelBufferGetHeight(previous) == CVPixelBufferGetHeight(current),
              CVPixelBufferGetPixelFormatType(previous) == CVPixelBufferGetPixelFormatType(current),
              isNV12(CVPixelBufferGetPixelFormatType(current)),
              CVPixelBufferGetPlaneCount(previous) == 2,
              CVPixelBufferGetPlaneCount(current) == 2,
              CVPixelBufferLockBaseAddress(previous, .readOnly) == kCVReturnSuccess
        else { return true }
        defer { CVPixelBufferUnlockBaseAddress(previous, .readOnly) }
        guard CVPixelBufferLockBaseAddress(current, .readOnly) == kCVReturnSuccess else {
            return true
        }
        defer { CVPixelBufferUnlockBaseAddress(current, .readOnly) }

        for plane in 0..<2 {
            guard let previousBase = CVPixelBufferGetBaseAddressOfPlane(previous, plane),
                  let currentBase = CVPixelBufferGetBaseAddressOfPlane(current, plane)
            else { return true }
            let previousStride = CVPixelBufferGetBytesPerRowOfPlane(previous, plane)
            let currentStride = CVPixelBufferGetBytesPerRowOfPlane(current, plane)
            let bytesPerSample = plane == 0 ? 1 : 2
            let rowBytes = CVPixelBufferGetWidthOfPlane(current, plane) * bytesPerSample
            let rowCount = CVPixelBufferGetHeightOfPlane(current, plane)
            guard rowBytes <= previousStride, rowBytes <= currentStride,
                  rowCount == CVPixelBufferGetHeightOfPlane(previous, plane)
            else { return true }

            for row in 0..<rowCount {
                if memcmp(
                    previousBase.advanced(by: row * previousStride),
                    currentBase.advanced(by: row * currentStride),
                    rowBytes
                ) != 0 {
                    return true
                }
            }
        }
        return false
    }

    private static func isNV12(_ pixelFormat: OSType) -> Bool {
        pixelFormat == kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
            || pixelFormat == kCVPixelFormatType_420YpCbCr8BiPlanarFullRange
    }
}
