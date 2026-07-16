import WebRTC
import XCTest
@testable import WebRTCScreencast

final class IceServerProviderTests: XCTestCase {
    func testDirectBaselineUsesAllUDPAndNoServer() throws {
        let result = try IceServerProvider.make(profile: .directBaseline, turn: nil)

        XCTAssertEqual(result.configuration.iceTransportPolicy, .all)
        XCTAssertEqual(result.configuration.tcpCandidatePolicy, .disabled)
        XCTAssertTrue(result.configuration.iceServers.isEmpty)
        XCTAssertEqual(result.evidence.profile, .directBaseline)
        XCTAssertNil(result.evidence.turnURL)
    }

    func testProductionUsesRelayOnlyUDPAndOneServer() throws {
        let credentials = TURNCredentials(
            url: try XCTUnwrap(URL(string: "turn:turn.example.test:3478?transport=udp")),
            username: "credential-user",
            password: "credential-password"
        )
        let result = try IceServerProvider.make(profile: .productionRelay, turn: credentials)

        XCTAssertEqual(result.configuration.iceTransportPolicy, .relay)
        XCTAssertEqual(result.configuration.tcpCandidatePolicy, .disabled)
        XCTAssertEqual(result.configuration.iceServers.count, 1)
        XCTAssertEqual(result.configuration.iceServers[0].urlStrings, [credentials.url.absoluteString])
        XCTAssertEqual(result.configuration.iceServers[0].username, credentials.username)
        XCTAssertEqual(result.configuration.iceServers[0].credential, credentials.password)
        XCTAssertEqual(result.evidence.turnURL, credentials.url.absoluteString)
        XCTAssertFalse(String(describing: result.evidence).contains(credentials.username))
        XCTAssertFalse(String(describing: result.evidence).contains(credentials.password))
    }

    func testProductionRejectsMissingOrNonUDPServer() throws {
        XCTAssertThrowsError(try IceServerProvider.make(profile: .productionRelay, turn: nil))
        for value in [
            "turn:turn.example.test:3478",
            "turn:turn.example.test:3478?transport=tcp",
            "turns:turn.example.test:5349?transport=udp",
        ] {
            let credentials = TURNCredentials(
                url: try XCTUnwrap(URL(string: value)),
                username: "user",
                password: "password"
            )
            XCTAssertThrowsError(try IceServerProvider.make(profile: .productionRelay, turn: credentials))
        }
    }
}
