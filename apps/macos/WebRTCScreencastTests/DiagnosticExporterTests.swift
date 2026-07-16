import Foundation
import XCTest
@testable import WebRTCScreencast

final class DiagnosticExporterTests: XCTestCase {
    func testBindingCanonicalSessionIDRewritesBufferedRecords() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let recorder = try MetricsRecorder(
            directory: directory,
            context: MetricsContext(
                schemaVersion: 1,
                sessionID: "local-provisional-id",
                role: .sender,
                profile: .directBaseline,
                effectiveConfigHash: "hash-1",
                tuningRevision: 1
            )
        )

        try await recorder.record(event: "signaling_connected")
        try await recorder.bindSessionID("server-session-id")
        try await recorder.record(event: "peer_paired")
        try await recorder.close()

        let data = try Data(contentsOf: directory.appending(path: "metrics.jsonl"))
        let records = try String(decoding: data, as: UTF8.self).split(separator: "\n").map {
            try XCTUnwrap(JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any])
        }
        XCTAssertEqual(records.count, 2)
        XCTAssertEqual(Set(records.compactMap { $0["session_id"] as? String }), ["server-session-id"])
    }

    func testConcurrentRecorderWritesOneSanitizedJSONObjectPerLine() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let recorder = try MetricsRecorder(
            directory: directory,
            context: MetricsContext(
                schemaVersion: 1,
                sessionID: "session-1",
                role: .sender,
                profile: .productionRelay,
                effectiveConfigHash: "hash-1",
                tuningRevision: 7
            )
        )

        try await withThrowingTaskGroup(of: Void.self) { group in
            for index in 0..<50 {
                group.addTask {
                    try await recorder.record(
                        event: "sample",
                        fields: [
                            "index": .integer(index),
                            "sdp": .string("v=0 secret-sdp"),
                            "candidate": .string("candidate:secret"),
                            "pairing_code": .string("01ABCD23"),
                        ]
                    )
                }
            }
            try await group.waitForAll()
        }
        try await recorder.close()

        let data = try Data(contentsOf: directory.appending(path: "metrics.jsonl"))
        let lines = String(decoding: data, as: UTF8.self).split(separator: "\n")
        XCTAssertEqual(lines.count, 50)
        for line in lines {
            let object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any])
            XCTAssertEqual(object["schema_version"] as? Int, 1)
            XCTAssertEqual(object["session_id"] as? String, "session-1")
            XCTAssertEqual(object["role"] as? String, "sender")
            XCTAssertEqual(object["profile"] as? String, "production-relay")
            XCTAssertEqual(object["effective_config_hash"] as? String, "hash-1")
            XCTAssertEqual(object["tuning_revision"] as? Int, 7)
            XCTAssertNotNil(object["wall_time"])
            XCTAssertNotNil(object["monotonic_ns"])
            let fields = try XCTUnwrap(object["fields"] as? [String: Any])
            XCTAssertEqual(fields["sdp"] as? String, "<redacted>")
            XCTAssertEqual(fields["candidate"] as? String, "<redacted>")
            XCTAssertEqual(fields["pairing_code"] as? String, "<redacted>")
        }
        let text = String(decoding: data, as: UTF8.self)
        XCTAssertFalse(text.contains("01ABCD23"))
        XCTAssertFalse(text.contains("secret-sdp"))
        XCTAssertFalse(text.contains("candidate:secret"))
    }

    func testExporterCreatesManifestAndZip() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        try Data("one\n".utf8).write(to: directory.appending(path: "metrics.jsonl"))
        try Data("log\n".utf8).write(to: directory.appending(path: "webrtc.log"))
        let output = directory.deletingLastPathComponent().appending(path: "\(UUID().uuidString).zip")
        defer { try? FileManager.default.removeItem(at: output) }

        let result = try await DiagnosticExporter.export(
            sessionDirectory: directory,
            outputURL: output,
            forbiddenSecrets: ["turn-password"]
        )

        XCTAssertEqual(result.archiveURL, output)
        XCTAssertEqual(Set(result.manifest.files.map(\.path)), Set(["metrics.jsonl", "webrtc.log"]))
        XCTAssertTrue(FileManager.default.fileExists(atPath: output.path))
        XCTAssertGreaterThan((try FileManager.default.attributesOfItem(atPath: output.path)[.size] as? NSNumber)?.intValue ?? 0, 0)
    }

    func testExporterAbortsWhenAnyFileContainsInjectedSecret() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        try Data("safe prefix injected-turn-password suffix".utf8)
            .write(to: directory.appending(path: "webrtc.log"))

        await XCTAssertThrowsErrorAsyncValue {
            _ = try await DiagnosticExporter.export(
                sessionDirectory: directory,
                outputURL: directory.appending(path: "out.zip"),
                forbiddenSecrets: ["injected-turn-password"]
            )
        }
    }

    func testExporterRejectsRawLibWebRTCArtifactsEvenWithoutKnownTURNSecrets() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        try Data("binary event data".utf8).write(to: directory.appending(path: "rtc-event.log"))

        do {
            _ = try await DiagnosticExporter.export(
                sessionDirectory: directory,
                outputURL: directory.appending(path: "out.zip"),
                forbiddenSecrets: []
            )
            XCTFail("Expected raw libwebrtc artifact rejection")
        } catch {
            XCTAssertEqual(
                error as? DiagnosticExporterError,
                .unsupportedSensitiveArtifact(path: "rtc-event.log")
            )
        }
    }

    func testExporterDoesNotSkipHiddenSensitiveArtifacts() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        try Data("raw log".utf8).write(to: directory.appending(path: ".webrtc_log_0"))

        do {
            _ = try await DiagnosticExporter.export(
                sessionDirectory: directory,
                outputURL: directory.appending(path: "out.zip"),
                forbiddenSecrets: []
            )
            XCTFail("Expected hidden raw artifact rejection")
        } catch {
            XCTAssertEqual(
                error as? DiagnosticExporterError,
                .unsupportedSensitiveArtifact(path: ".webrtc_log_0")
            )
        }
    }

    func testExporterScansHiddenFilesForConfiguredSecrets() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        try Data("hidden-turn-secret".utf8).write(to: directory.appending(path: ".diagnostic-cache"))

        do {
            _ = try await DiagnosticExporter.export(
                sessionDirectory: directory,
                outputURL: directory.appending(path: "out.zip"),
                forbiddenSecrets: ["hidden-turn-secret"]
            )
            XCTFail("Expected hidden secret rejection")
        } catch {
            XCTAssertEqual(
                error as? DiagnosticExporterError,
                .secretFound(path: ".diagnostic-cache")
            )
        }
    }

    private func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}

private func XCTAssertThrowsErrorAsyncValue<T>(
    _ expression: () async throws -> T,
    file: StaticString = #filePath,
    line: UInt = #line
) async {
    do {
        _ = try await expression()
        XCTFail("Expected error", file: file, line: line)
    } catch {}
}
