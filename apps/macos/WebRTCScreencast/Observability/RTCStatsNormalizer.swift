import Foundation
@preconcurrency import WebRTC

struct RTCStatisticsBatch: Equatable, Sendable {
    let timestampUs: Int64
    let statistics: [RTCStatisticSnapshot]
}

enum RTCStatsSnapshotAdapter {
    static func makeBatch(from report: RTCStatisticsReport) -> RTCStatisticsBatch {
        RTCStatisticsBatch(
            timestampUs: Int64(report.timestamp_us),
            statistics: report.statistics.values.map { statistic in
                RTCStatisticSnapshot(
                    id: statistic.id,
                    type: statistic.type,
                    values: statistic.values.compactMapValues(convert)
                )
            }
        )
    }

    private static func convert(_ value: NSObject) -> RTCStatisticValue? {
        if let value = value as? NSString { return .string(value as String) }
        if let value = value as? NSNumber {
            if CFGetTypeID(value) == CFBooleanGetTypeID() { return .bool(value.boolValue) }
            return .number(value.doubleValue)
        }
        return nil
    }
}

struct NormalizedVideoRTPStats: Equatable, Sendable {
    let id: String
    let bytes: UInt64?
    let frames: UInt64?
    let framesDropped: UInt64?
    let bitrateBps: Double?
    let framesPerSecond: Double?
    let averageQP: Double?
    let codecMimeType: String?
    let implementation: String?
    let decoderImplementation: String?
}

struct NormalizedRemoteInboundStats: Equatable, Sendable {
    let roundTripTimeMs: Double?
    let packetsLost: Int64?
}

struct NormalizedRTCStatsSample: Equatable, Sendable {
    let timestampUs: Int64
    let outbound: NormalizedVideoRTPStats?
    let remoteInbound: NormalizedRemoteInboundStats?
    let inbound: NormalizedVideoRTPStats?
    let selectedPath: SelectedPathEvidence
}

struct RTCStatsNormalizer: Sendable {
    private struct PreviousCounter: Sendable {
        let timestampUs: Int64
        let bytes: UInt64?
        let frames: UInt64?
    }

    private let profile: ICEProfile
    private var previousByID: [String: PreviousCounter] = [:]

    init(profile: ICEProfile) {
        self.profile = profile
    }

    mutating func normalize(
        timestampUs: Int64,
        statistics: [RTCStatisticSnapshot]
    ) -> NormalizedRTCStatsSample {
        let byID = Dictionary(uniqueKeysWithValues: statistics.map { ($0.id, $0) })
        let outboundStatistic = statistics.first { isVideoRTP($0, type: "outbound-rtp") }
        let inboundStatistic = statistics.first { isVideoRTP($0, type: "inbound-rtp") }
        let outbound = outboundStatistic.map { normalizeVideo($0, timestampUs: timestampUs, byID: byID, outbound: true) }
        let inbound = inboundStatistic.map { normalizeVideo($0, timestampUs: timestampUs, byID: byID, outbound: false) }

        let remoteInbound: NormalizedRemoteInboundStats?
        if let remoteID = outboundStatistic?.values["remoteId"]?.stringValue,
           let statistic = byID[remoteID],
           statistic.type == "remote-inbound-rtp" {
            remoteInbound = NormalizedRemoteInboundStats(
                roundTripTimeMs: statistic.values["roundTripTime"]?.doubleValue.map { $0 * 1_000 },
                packetsLost: statistic.values["packetsLost"]?.int64Value
            )
        } else {
            remoteInbound = nil
        }

        return NormalizedRTCStatsSample(
            timestampUs: timestampUs,
            outbound: outbound,
            remoteInbound: remoteInbound,
            inbound: inbound,
            selectedPath: SelectedPathVerifier.verify(profile: profile, statistics: statistics)
        )
    }

    private func isVideoRTP(_ statistic: RTCStatisticSnapshot, type: String) -> Bool {
        guard statistic.type == type else { return false }
        return statistic.values["kind"]?.stringValue == "video"
            || statistic.values["mediaType"]?.stringValue == "video"
    }

    private mutating func normalizeVideo(
        _ statistic: RTCStatisticSnapshot,
        timestampUs: Int64,
        byID: [String: RTCStatisticSnapshot],
        outbound: Bool
    ) -> NormalizedVideoRTPStats {
        let bytesKey = outbound ? "bytesSent" : "bytesReceived"
        let framesKey = outbound ? "framesEncoded" : "framesDecoded"
        let bytes = statistic.values[bytesKey]?.uint64Value
        let frames = statistic.values[framesKey]?.uint64Value
        let previous = previousByID[statistic.id]
        let elapsedSeconds = previous.map { Double(timestampUs - $0.timestampUs) / 1_000_000 }
        let bitrate = rateDelta(current: bytes, previous: previous?.bytes, elapsedSeconds: elapsedSeconds).map { $0 * 8 }
        let frameRate = rateDelta(current: frames, previous: previous?.frames, elapsedSeconds: elapsedSeconds)
        previousByID[statistic.id] = PreviousCounter(timestampUs: timestampUs, bytes: bytes, frames: frames)

        let qpSum = statistic.values["qpSum"]?.doubleValue
        let averageQP: Double?
        if let qpSum, let frames, frames > 0 {
            averageQP = qpSum / Double(frames)
        } else {
            averageQP = nil
        }
        let codec = statistic.values["codecId"]?.stringValue.flatMap { byID[$0] }
        return NormalizedVideoRTPStats(
            id: statistic.id,
            bytes: bytes,
            frames: frames,
            framesDropped: statistic.values["framesDropped"]?.uint64Value,
            bitrateBps: bitrate,
            framesPerSecond: frameRate,
            averageQP: averageQP,
            codecMimeType: codec?.values["mimeType"]?.stringValue,
            implementation: outbound ? statistic.values["encoderImplementation"]?.stringValue : nil,
            decoderImplementation: outbound ? nil : statistic.values["decoderImplementation"]?.stringValue
        )
    }

    private func rateDelta(
        current: UInt64?,
        previous: UInt64?,
        elapsedSeconds: Double?
    ) -> Double? {
        guard let current, let previous, current >= previous,
              let elapsedSeconds, elapsedSeconds > 0 else { return nil }
        return Double(current - previous) / elapsedSeconds
    }
}

extension RTCStatisticValue {
    var doubleValue: Double? {
        switch self {
        case let .number(value):
            return value.isFinite ? value : nil
        case let .string(value):
            return Double(value).flatMap { $0.isFinite ? $0 : nil }
        case .bool:
            return nil
        }
    }

    var uint64Value: UInt64? {
        guard let value = doubleValue, value >= 0, value.rounded(.towardZero) == value else { return nil }
        return UInt64(exactly: value)
    }

    var int64Value: Int64? {
        guard let value = doubleValue, value.rounded(.towardZero) == value else { return nil }
        return Int64(exactly: value)
    }
}
