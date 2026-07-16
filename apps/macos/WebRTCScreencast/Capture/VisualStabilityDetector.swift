import CoreVideo
import Foundation

struct VisualStabilityConfiguration: Equatable, Sendable {
    let stableDuration: Duration
    let sampleDeltaThreshold: UInt8
    let maximumChangedSampleRatio: Double
    let minimumMotionSampleRatio: Double

    static let desktopClarity = VisualStabilityConfiguration(
        stableDuration: .milliseconds(600),
        sampleDeltaThreshold: 8,
        maximumChangedSampleRatio: 0.02,
        minimumMotionSampleRatio: 0.08
    )
}

enum VisualStabilityMode: String, Equatable, Sendable {
    case motion
    case settling
    case staticClarity = "static_clarity"
}

enum VisualStabilityTransition: Equatable, Sendable {
    case none
    case enterStaticClarity
    case exitStaticClarity
}

struct VisualStabilityDecision: Equatable, Sendable {
    let mode: VisualStabilityMode
    let transition: VisualStabilityTransition
    let changedSampleRatio: Double
}

struct VisualStabilityDetector: Sendable {
    private let configuration: VisualStabilityConfiguration
    private var previousSamples: [UInt8]?
    private var settlingStartedAt: Duration?
    private var lastTimestamp: Duration?
    private(set) var mode: VisualStabilityMode = .motion

    init(configuration: VisualStabilityConfiguration = .desktopClarity) {
        self.configuration = configuration
    }

    mutating func evaluate(samples: [UInt8], timestamp: Duration) -> VisualStabilityDecision {
        guard !samples.isEmpty else {
            return VisualStabilityDecision(mode: mode, transition: .none, changedSampleRatio: 1)
        }
        if let lastTimestamp, timestamp < lastTimestamp {
            return VisualStabilityDecision(mode: mode, transition: .none, changedSampleRatio: 1)
        }
        lastTimestamp = timestamp

        guard let previousSamples, previousSamples.count == samples.count else {
            self.previousSamples = samples
            settlingStartedAt = nil
            let transition: VisualStabilityTransition = mode == .staticClarity ? .exitStaticClarity : .none
            mode = .motion
            return VisualStabilityDecision(mode: mode, transition: transition, changedSampleRatio: 1)
        }

        var changedSamples = 0
        for (previous, current) in zip(previousSamples, samples) {
            let delta = previous > current ? previous - current : current - previous
            if delta >= configuration.sampleDeltaThreshold {
                changedSamples += 1
            }
        }
        self.previousSamples = samples
        let changedSampleRatio = Double(changedSamples) / Double(samples.count)

        let motionThreshold = mode == .staticClarity
            ? configuration.minimumMotionSampleRatio
            : configuration.maximumChangedSampleRatio
        guard changedSampleRatio <= motionThreshold else {
            let transition: VisualStabilityTransition = mode == .staticClarity ? .exitStaticClarity : .none
            mode = .motion
            settlingStartedAt = nil
            return VisualStabilityDecision(
                mode: mode,
                transition: transition,
                changedSampleRatio: changedSampleRatio
            )
        }

        switch mode {
        case .motion:
            mode = .settling
            settlingStartedAt = timestamp
        case .settling:
            if let settlingStartedAt,
               timestamp - settlingStartedAt >= configuration.stableDuration {
                mode = .staticClarity
                return VisualStabilityDecision(
                    mode: mode,
                    transition: .enterStaticClarity,
                    changedSampleRatio: changedSampleRatio
                )
            }
        case .staticClarity:
            break
        }
        return VisualStabilityDecision(
            mode: mode,
            transition: .none,
            changedSampleRatio: changedSampleRatio
        )
    }
}

enum LumaFrameSampler {
    static let gridWidth = 96
    static let gridHeight = 54

    static func sample(pixelBuffer: CVPixelBuffer) -> [UInt8]? {
        guard CVPixelBufferGetPlaneCount(pixelBuffer) > 0 else { return nil }
        CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly) }
        guard let baseAddress = CVPixelBufferGetBaseAddressOfPlane(pixelBuffer, 0) else { return nil }
        let width = CVPixelBufferGetWidthOfPlane(pixelBuffer, 0)
        let height = CVPixelBufferGetHeightOfPlane(pixelBuffer, 0)
        let bytesPerRow = CVPixelBufferGetBytesPerRowOfPlane(pixelBuffer, 0)
        let bytes = baseAddress.assumingMemoryBound(to: UInt8.self)
        return sample(
            width: width,
            height: height,
            gridWidth: gridWidth,
            gridHeight: gridHeight,
            pixelAt: { x, y in bytes[(y * bytesPerRow) + x] }
        )
    }

    static func sample(
        width: Int,
        height: Int,
        gridWidth: Int,
        gridHeight: Int,
        pixelAt: (_ x: Int, _ y: Int) -> UInt8
    ) -> [UInt8] {
        guard width > 0, height > 0, gridWidth > 0, gridHeight > 0 else { return [] }
        let columns = min(width, gridWidth)
        let rows = min(height, gridHeight)
        var result: [UInt8] = []
        result.reserveCapacity(columns * rows)
        for row in 0..<rows {
            let yStart = (row * height) / rows
            let yEnd = max(yStart + 1, ((row + 1) * height) / rows)
            let y0 = min(yEnd - 1, yStart + ((yEnd - yStart) / 4))
            let y1 = min(yEnd - 1, yStart + ((3 * (yEnd - yStart)) / 4))
            for column in 0..<columns {
                let xStart = (column * width) / columns
                let xEnd = max(xStart + 1, ((column + 1) * width) / columns)
                let x0 = min(xEnd - 1, xStart + ((xEnd - xStart) / 4))
                let x1 = min(xEnd - 1, xStart + ((3 * (xEnd - xStart)) / 4))
                let total = UInt16(pixelAt(x0, y0))
                    + UInt16(pixelAt(x1, y0))
                    + UInt16(pixelAt(x0, y1))
                    + UInt16(pixelAt(x1, y1))
                result.append(UInt8(total / 4))
            }
        }
        return result
    }
}
