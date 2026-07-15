import Darwin
import XCTest
@testable import WebRTCScreencast

final class LaunchOptionsTests: XCTestCase {
    func testDirectPairingCodeIsNormalizedEagerly() throws {
        let options = try LaunchOptions.parse([
            "app", "--role", "sender", "--pairing-code", "AB12-CD34", "--source", "main",
        ])

        XCTAssertEqual(options.pairingCode, "AB12CD34")
        XCTAssertNil(options.pairingCodeFile)
        XCTAssertEqual(options.source, .mainDisplayMirror)
    }

    func testDirectPairingCodeRejectsMissingInvalidAndConflictingValues() throws {
        XCTAssertThrowsError(try LaunchOptions.parse(["app", "--pairing-code"])) { error in
            XCTAssertEqual(error as? LaunchOptionsError, .missingValue("--pairing-code"))
        }
        XCTAssertThrowsError(try LaunchOptions.parse(["app", "--pairing-code", "not-a-code"])) { error in
            XCTAssertEqual(
                error as? LaunchOptionsError,
                .invalidValue(option: "--pairing-code", value: "not-a-code")
            )
        }
        XCTAssertThrowsError(try LaunchOptions.parse([
            "app", "--pairing-code", "AB12CD34", "--pairing-code-file", "/tmp/code",
        ])) { error in
            XCTAssertEqual(
                error as? LaunchOptionsError,
                .conflictingOptions("--pairing-code", "--pairing-code-file")
            )
        }
    }

    func testParsesDualProcessAutomationArguments() throws {
        let options = try LaunchOptions.parse([
            "app", "--role", "sender", "--profile", "direct-baseline",
            "--config", "/tmp/runtime.json", "--pairing-code-file", "/tmp/code",
            "--source", "virtual", "--exclude-receiver-pid", "123", "--run-seconds", "20",
            "--media-baseline",
        ])

        XCTAssertEqual(options.role, .sender)
        XCTAssertEqual(options.profile, .directBaseline)
        XCTAssertEqual(options.source, .virtualExtendedDisplay)
        XCTAssertEqual(options.excludedReceiverPID, 123)
        XCTAssertEqual(options.runSeconds, 20)
        XCTAssertTrue(options.mediaBaseline)
    }

    func testPairingCodeFileIsMode0600AndReadable() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appending(path: "pairing-code")

        try PairingCodeFile.write("ABCD1234", to: file)
        let attributes = try FileManager.default.attributesOfItem(atPath: file.path)
        XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o600)
        let code = try await PairingCodeFile.waitForCode(at: file, timeout: .seconds(1))
        XCTAssertEqual(code, "ABCD1234")
    }
}
