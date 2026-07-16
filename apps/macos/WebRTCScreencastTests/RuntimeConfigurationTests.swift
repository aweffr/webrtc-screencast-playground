import Foundation
import XCTest
@preconcurrency import WebRTC
@testable import WebRTCScreencast

final class RuntimeConfigurationTests: XCTestCase {
    func testBundledCastTuningDefersAppleRateControlButKeepsReceiverLowLatency() throws {
        let data = try Data(contentsOf: repositoryRoot().appending(path: "config/cast-tuning.default.json"))
        let root = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let encoder = try XCTUnwrap(root["encoder"] as? [String: Any])
        let receiver = try XCTUnwrap(root["receiver"] as? [String: Any])

        XCTAssertEqual(root["schema_version"] as? Int, 2)
        XCTAssertEqual(encoder["h264_profile"] as? String, "CONSTRAINED_BASELINE")
        XCTAssertEqual(encoder["video_toolbox_low_latency_rate_control"] as? Bool, false)
        XCTAssertEqual(receiver["android_decoder_low_latency"] as? Bool, true)
        XCTAssertEqual(receiver["prerender_smoothing"] as? Bool, false)
        XCTAssertNoThrow(try RTCCastTuningConfiguration(jsonData: data))
    }

    func testDirectBaselineDoesNotRequireTURN() throws {
        let configuration = try RuntimeConfiguration.decode(Data(#"""
        {
          "signaling_url": "ws://127.0.0.1:8080/ws",
          "ice_profile": "direct-baseline",
          "turn": null,
          "metrics_directory": "/tmp/metrics",
          "excluded_receiver_pid": 123
        }
        """#.utf8))

        XCTAssertEqual(configuration.signalingURL, URL(string: "ws://127.0.0.1:8080/ws"))
        XCTAssertEqual(configuration.iceProfile, .directBaseline)
        XCTAssertNil(configuration.turn)
        XCTAssertEqual(configuration.excludedReceiverPID, 123)
        XCTAssertNoThrow(try configuration.validate())
    }

    func testProductionRelayRequiresExplicitUDPAndCredentials() throws {
        let valid = try decodeRelay(url: "turn:turn.example.test:3478?transport=udp", username: "alice", password: "secret")
        XCTAssertNoThrow(try valid.validate())

        let tcp = try decodeRelay(url: "turn:turn.example.test:3478?transport=tcp", username: "alice", password: "secret")
        XCTAssertThrowsError(try tcp.validate())

        let missingTransport = try decodeRelay(url: "turn:turn.example.test:3478", username: "alice", password: "secret")
        XCTAssertThrowsError(try missingTransport.validate())

        let missingUsername = try decodeRelay(url: "turn:turn.example.test:3478?transport=udp", username: "", password: "secret")
        XCTAssertThrowsError(try missingUsername.validate())

        let missingPassword = try decodeRelay(url: "turn:turn.example.test:3478?transport=udp", username: "alice", password: "")
        XCTAssertThrowsError(try missingPassword.validate())
    }

    func testSignalingAllowsOnlyWSAndWSS() throws {
        for scheme in ["ws", "wss"] {
            let configuration = try RuntimeConfiguration.decode(Data(#"""
            {
              "signaling_url": "\#(scheme)://cast.example.test/ws",
              "ice_profile": "direct-baseline",
              "turn": null,
              "metrics_directory": "/tmp/metrics",
              "excluded_receiver_pid": null
            }
            """#.utf8))
            XCTAssertNoThrow(try configuration.validate())
        }

        let configuration = try RuntimeConfiguration.decode(Data(#"""
        {
          "signaling_url": "https://cast.example.test/ws",
          "ice_profile": "direct-baseline",
          "turn": null,
          "metrics_directory": "/tmp/metrics",
          "excluded_receiver_pid": null
        }
        """#.utf8))
        XCTAssertThrowsError(try configuration.validate())
    }

    func testStaticMaxQpDefaultsTo24AndAcceptsExperimentValues() throws {
        let defaultConfiguration = try RuntimeConfiguration.decode(Data(#"""
        {
          "signaling_url": "ws://127.0.0.1:8080/ws",
          "ice_profile": "direct-baseline",
          "turn": null,
          "metrics_directory": "/tmp/metrics",
          "excluded_receiver_pid": null
        }
        """#.utf8))
        XCTAssertEqual(defaultConfiguration.staticMaxQp, 24)

        for value in [24, 22, 20, 18] {
            let configuration = try RuntimeConfiguration.decode(Data(#"""
            {
              "signaling_url": "ws://127.0.0.1:8080/ws",
              "ice_profile": "direct-baseline",
              "turn": null,
              "metrics_directory": "/tmp/metrics",
              "excluded_receiver_pid": null,
              "static_max_qp": \#(value)
            }
            """#.utf8))
            XCTAssertEqual(configuration.staticMaxQp, value)
            XCTAssertNoThrow(try configuration.validate())
        }
    }

    func testStaticMaxQpRejectsValuesOutsideH264Range() throws {
        for value in [-1, 52] {
            let configuration = try RuntimeConfiguration.decode(Data(#"""
            {
              "signaling_url": "ws://127.0.0.1:8080/ws",
              "ice_profile": "direct-baseline",
              "turn": null,
              "metrics_directory": "/tmp/metrics",
              "excluded_receiver_pid": null,
              "static_max_qp": \#(value)
            }
            """#.utf8))
            XCTAssertThrowsError(try configuration.validate())
        }
    }

    func testLoadUsesExplicitConfigPath() throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let path = directory.appending(path: "runtime.json")
        try Data(#"""
        {
          "signaling_url": "ws://127.0.0.1:9000/ws",
          "ice_profile": "direct-baseline",
          "turn": null,
          "metrics_directory": "/tmp/metrics",
          "excluded_receiver_pid": null
        }
        """#.utf8).write(to: path)

        let configuration = try RuntimeConfiguration.load(arguments: ["app", "--config", path.path])
        XCTAssertEqual(configuration.signalingURL.port, 9000)
    }

    func testEffectiveConfigurationNeverContainsCredentialsAndHasStableHash() throws {
        let configuration = try decodeRelay(url: "turn:turn.example.test:3478?transport=udp", username: "credential-user", password: "credential-password")
        let first = try configuration.effective(role: .sender, source: .mainDisplayMirror)
        let second = try configuration.effective(role: .sender, source: .mainDisplayMirror)
        let encoded = String(decoding: try first.canonicalJSON(), as: UTF8.self)

        XCTAssertEqual(first.hash, second.hash)
        XCTAssertFalse(encoded.contains("credential-user"))
        XCTAssertFalse(encoded.contains("credential-password"))
        XCTAssertTrue(encoded.contains("production-relay"))
        XCTAssertTrue(encoded.contains("sender"))
    }

    func testRuntimeConfigurationDoesNotDescribeSecrets() throws {
        let configuration = try decodeRelay(url: "turn:turn.example.test:3478?transport=udp", username: "credential-user", password: "credential-password")
        let reflected = String(reflecting: configuration)
        XCTAssertFalse(reflected.contains("credential-user"))
        XCTAssertFalse(reflected.contains("credential-password"))
    }

    private func decodeRelay(url: String, username: String, password: String) throws -> RuntimeConfiguration {
        let object: [String: Any] = [
            "signaling_url": "wss://cast.example.test/ws",
            "ice_profile": "production-relay",
            "turn": ["url": url, "username": username, "password": password],
            "metrics_directory": "/tmp/metrics",
            "excluded_receiver_pid": NSNull(),
        ]
        return try RuntimeConfiguration.decode(JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]))
    }

    private func repositoryRoot() -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }
}
