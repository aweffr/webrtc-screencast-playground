import Darwin
import Foundation

enum LaunchOptionsError: Error, LocalizedError, Equatable {
    case missingValue(String)
    case invalidValue(option: String, value: String)
    case conflictingOptions(String, String)

    var errorDescription: String? {
        switch self {
        case .missingValue(let option): "Missing value for \(option)"
        case let .invalidValue(option, value): "Invalid value '\(value)' for \(option)"
        case let .conflictingOptions(first, second): "Conflicting options: \(first) and \(second)"
        }
    }
}

struct LaunchOptions: Equatable, Sendable {
    var role: CastingRole?
    var profile: ICEProfile?
    var configPath: String?
    var castTuningConfigPath: String?
    var pairingCode: String?
    var pairingCodeFile: String?
    var source: CaptureSourceKind?
    var excludedReceiverPID: pid_t?
    var runSeconds: Double?
    var mediaBaseline = false
    var markerEvidence = false

    var usesMarkerProbe: Bool { mediaBaseline || markerEvidence }

    static func parse(_ arguments: [String]) throws -> LaunchOptions {
        var result = LaunchOptions()
        var index = arguments.first == arguments.first(where: { !$0.hasPrefix("--") }) ? 1 : 0
        while index < arguments.count {
            let option = arguments[index]
            guard option.hasPrefix("--") else { index += 1; continue }
            if option == "--media-baseline" {
                result.mediaBaseline = true
                index += 1
                continue
            }
            if option == "--marker-evidence" {
                result.markerEvidence = true
                index += 1
                continue
            }
            guard arguments.indices.contains(index + 1) else { throw LaunchOptionsError.missingValue(option) }
            let value = arguments[index + 1]
            switch option {
            case "--role":
                guard let role = CastingRole(rawValue: value) else { throw LaunchOptionsError.invalidValue(option: option, value: value) }
                result.role = role
            case "--profile":
                guard let profile = ICEProfile(rawValue: value) else { throw LaunchOptionsError.invalidValue(option: option, value: value) }
                result.profile = profile
            case "--config":
                result.configPath = value
            case "--cast-tuning-config":
                result.castTuningConfigPath = value
            case "--pairing-code-file":
                result.pairingCodeFile = value
            case "--pairing-code":
                do {
                    result.pairingCode = try PairingCode.normalize(value)
                } catch {
                    throw LaunchOptionsError.invalidValue(option: option, value: value)
                }
            case "--source":
                switch value {
                case "main", CaptureSourceKind.mainDisplayMirror.rawValue:
                    result.source = .mainDisplayMirror
                case "virtual", CaptureSourceKind.virtualExtendedDisplay.rawValue:
                    result.source = .virtualExtendedDisplay
                default:
                    throw LaunchOptionsError.invalidValue(option: option, value: value)
                }
            case "--exclude-receiver-pid":
                guard let pid = pid_t(value), pid > 0 else { throw LaunchOptionsError.invalidValue(option: option, value: value) }
                result.excludedReceiverPID = pid
            case "--run-seconds":
                guard let seconds = Double(value), seconds > 0 else { throw LaunchOptionsError.invalidValue(option: option, value: value) }
                result.runSeconds = seconds
            default:
                throw LaunchOptionsError.invalidValue(option: option, value: value)
            }
            index += 2
        }
        if result.pairingCode != nil, result.pairingCodeFile != nil {
            throw LaunchOptionsError.conflictingOptions("--pairing-code", "--pairing-code-file")
        }
        return result
    }
}

enum PairingCodeFile {
    static func write(_ code: String, to url: URL, fileManager: FileManager = .default) throws {
        let normalized = try PairingCode.normalize(code)
        let directory = url.deletingLastPathComponent()
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        let temporary = directory.appending(path: ".\(url.lastPathComponent).\(UUID().uuidString)")
        try Data((normalized + "\n").utf8).write(to: temporary, options: .atomic)
        guard chmod(temporary.path, S_IRUSR | S_IWUSR) == 0 else {
            try? fileManager.removeItem(at: temporary)
            throw POSIXError(.EACCES)
        }
        if fileManager.fileExists(atPath: url.path) { try fileManager.removeItem(at: url) }
        try fileManager.moveItem(at: temporary, to: url)
    }

    static func waitForCode(
        at url: URL,
        timeout: Duration = .seconds(30),
        pollInterval: Duration = .milliseconds(100)
    ) async throws -> String {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while clock.now < deadline {
            if let data = FileManager.default.contents(atPath: url.path),
               let text = String(data: data, encoding: .utf8),
               let code = try? PairingCode.normalize(text) {
                return code
            }
            try await Task.sleep(for: pollInterval)
        }
        throw CocoaError(.fileReadNoSuchFile)
    }
}
