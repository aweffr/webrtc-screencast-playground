import Foundation

enum MetricsRecorderError: Error {
    case closed
    case invalidSessionID
    case sessionIDMismatch
}

actor MetricsRecorder {
    let fileURL: URL

    private let context: MetricsContext
    private var canonicalSessionID: String?
    private var pendingRecords: [PendingMetricsRecord] = []
    private var fileHandle: FileHandle?
    private let encoder: JSONEncoder

    init(directory: URL, context: MetricsContext, fileManager: FileManager = .default) throws {
        self.context = context
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        fileURL = directory.appending(path: "metrics.jsonl")
        if !fileManager.fileExists(atPath: fileURL.path) {
            fileManager.createFile(atPath: fileURL.path, contents: nil)
        }
        fileHandle = try FileHandle(forWritingTo: fileURL)
        try fileHandle?.seekToEnd()
        encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    }

    func record(event: String, fields: [String: JSONValue] = [:]) throws {
        guard fileHandle != nil else { throw MetricsRecorderError.closed }
        let pending = PendingMetricsRecord(
            wallTime: ISO8601DateFormatter().string(from: Date()),
            monotonicNs: UInt64(ProcessInfo.processInfo.systemUptime * 1_000_000_000),
            event: event,
            fields: Self.sanitize(fields)
        )
        guard let canonicalSessionID else {
            pendingRecords.append(pending)
            return
        }
        try write(pending, sessionID: canonicalSessionID)
    }

    func bindSessionID(_ sessionID: String) throws {
        guard !sessionID.isEmpty else { throw MetricsRecorderError.invalidSessionID }
        if let canonicalSessionID {
            guard canonicalSessionID == sessionID else { throw MetricsRecorderError.sessionIDMismatch }
            return
        }
        canonicalSessionID = sessionID
        for pending in pendingRecords {
            try write(pending, sessionID: sessionID)
        }
        pendingRecords.removeAll(keepingCapacity: false)
    }

    private func write(_ pending: PendingMetricsRecord, sessionID: String) throws {
        guard let fileHandle else { throw MetricsRecorderError.closed }
        let record = MetricsRecord(
            schemaVersion: context.schemaVersion,
            sessionID: sessionID,
            role: context.role,
            profile: context.profile,
            effectiveConfigHash: context.effectiveConfigHash,
            tuningRevision: context.tuningRevision,
            wallTime: pending.wallTime,
            monotonicNs: pending.monotonicNs,
            event: pending.event,
            fields: pending.fields
        )
        var data = try encoder.encode(record)
        data.append(0x0A)
        try fileHandle.write(contentsOf: data)
    }

    func synchronize() throws {
        try fileHandle?.synchronize()
    }

    func close() throws {
        guard let fileHandle else { return }
        if canonicalSessionID == nil {
            try bindSessionID(context.sessionID)
        }
        try fileHandle.synchronize()
        try fileHandle.close()
        self.fileHandle = nil
    }

    private static func sanitize(_ fields: [String: JSONValue]) -> [String: JSONValue] {
        let sensitiveKeys: Set<String> = [
            "sdp", "candidate", "pairing_code", "turn_username", "turn_password", "username", "password",
        ]
        return fields.mapValues { value in sanitize(value) }.reduce(into: [:]) { result, item in
            let key = item.key.lowercased()
            result[item.key] = sensitiveKeys.contains(key) ? .string("<redacted>") : item.value
        }
    }

    private static func sanitize(_ value: JSONValue) -> JSONValue {
        switch value {
        case let .array(values):
            return .array(values.map(sanitize))
        case let .object(fields):
            return .object(sanitize(fields))
        default:
            return value
        }
    }
}

private struct PendingMetricsRecord {
    let wallTime: String
    let monotonicNs: UInt64
    let event: String
    let fields: [String: JSONValue]
}
