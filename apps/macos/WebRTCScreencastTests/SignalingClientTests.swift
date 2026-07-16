import Foundation
import XCTest
@testable import WebRTCScreencast

final class SignalingClientTests: XCTestCase {
    func testReceiverConnectsAndRegisters() async throws {
        let transport = TestWebSocketTransport()
        let client = SignalingClient(transport: transport, messageID: { "receiver-1" })
        let url = try XCTUnwrap(URL(string: "ws://127.0.0.1:8080/ws"))

        try await client.connect(url: url, role: .receiver)
        try await client.registerReceiver()

        let snapshot = await transport.snapshot()
        XCTAssertEqual(snapshot.connectedURLs, [url])
        XCTAssertEqual(snapshot.sent.count, 1)
        XCTAssertEqual(try SignalingCodec.decode(snapshot.sent[0]).payload, .receiverRegister)
        await client.close()
    }

    func testSenderJoinNormalizesPairingCode() async throws {
        let transport = TestWebSocketTransport()
        let client = SignalingClient(transport: transport, messageID: { "sender-1" })
        try await client.connect(url: XCTUnwrap(URL(string: "wss://cast.example.test/ws")), role: .sender)

        try await client.join(code: " 01ab-cd23 ")

        let snapshot = await transport.snapshot()
        let data = try XCTUnwrap(snapshot.sent.first)
        XCTAssertEqual(try SignalingCodec.decode(data).payload, .senderJoin(pairingCode: "01ABCD23"))
        await client.close()
    }

    func testRoleSpecificCommandsAreRejected() async throws {
        let receiverTransport = TestWebSocketTransport()
        let receiver = SignalingClient(transport: receiverTransport)
        try await receiver.connect(url: XCTUnwrap(URL(string: "ws://localhost/ws")), role: .receiver)
        await XCTAssertThrowsErrorAsync { try await receiver.join(code: "01ABCD23") }
        await receiver.close()

        let senderTransport = TestWebSocketTransport()
        let sender = SignalingClient(transport: senderTransport)
        try await sender.connect(url: XCTUnwrap(URL(string: "ws://localhost/ws")), role: .sender)
        await XCTAssertThrowsErrorAsync { try await sender.registerReceiver() }
        await sender.close()
    }

    func testIncomingMessagesUseOneReaderAndProduceEvents() async throws {
        let transport = TestWebSocketTransport()
        let client = SignalingClient(transport: transport)
        let stream = await client.events()
        try await client.connect(url: XCTUnwrap(URL(string: "ws://localhost/ws")), role: .receiver)

        let expected = SignalingEnvelope(
            messageID: "server-1",
            payload: .sessionPaired(sessionID: "session-1", role: .receiver)
        )
        await transport.enqueue(.success(try SignalingCodec.encode(expected)))

        var iterator = stream.makeAsyncIterator()
        let event = try await iterator.next()
        XCTAssertEqual(event, .message(expected))
        let snapshot = await transport.snapshot()
        XCTAssertEqual(snapshot.maximumActiveReceives, 1)
        await client.close()
    }

    func testConcurrentCallsAreWrittenSerially() async throws {
        let transport = TestWebSocketTransport(blockSends: true)
        let client = SignalingClient(transport: transport)
        try await client.connect(url: XCTUnwrap(URL(string: "ws://localhost/ws")), role: .sender)

        let first = Task { try await client.send(.sdpOffer("offer")) }
        await transport.waitUntilActiveSendCount(1)
        let second = Task { try await client.send(.iceComplete) }
        await Task.yield()
        let blockedSnapshot = await transport.snapshot()
        XCTAssertEqual(blockedSnapshot.maximumActiveSends, 1)

        await transport.releaseNextSend()
        try await first.value
        await transport.waitUntilActiveSendCount(1)
        await transport.releaseNextSend()
        try await second.value

        let sent = await transport.snapshot().sent
        XCTAssertEqual(sent.count, 2)
        XCTAssertEqual(try SignalingCodec.decode(sent[0]).payload, .sdpOffer("offer"))
        XCTAssertEqual(try SignalingCodec.decode(sent[1]).payload, .iceComplete)
        await client.close()
    }

    func testReaderFailureDoesNotReconnectAutomatically() async throws {
        let transport = TestWebSocketTransport()
        let client = SignalingClient(transport: transport)
        let stream = await client.events()
        try await client.connect(url: XCTUnwrap(URL(string: "ws://localhost/ws")), role: .receiver)
        await transport.enqueue(.failure(TestTransportError.disconnected))

        var iterator = stream.makeAsyncIterator()
        await XCTAssertThrowsErrorAsync { _ = try await iterator.next() }
        for _ in 0..<20 { await Task.yield() }

        let snapshot = await transport.snapshot()
        XCTAssertEqual(snapshot.connectedURLs.count, 1)
        XCTAssertEqual(snapshot.receiveCalls, 1)
        await client.close()
    }

    func testURLSessionTransportAcceptsOnlyWebSocketSchemes() async throws {
        let transport = URLSessionWebSocketTransport()
        XCTAssertNoThrow(try transport.validate(url: XCTUnwrap(URL(string: "ws://localhost/ws"))))
        XCTAssertNoThrow(try transport.validate(url: XCTUnwrap(URL(string: "wss://localhost/ws"))))
        XCTAssertThrowsError(try transport.validate(url: XCTUnwrap(URL(string: "https://localhost/ws"))))
    }

    func testURLSessionTransportEncodesProtocolJSONAsTextFrame() throws {
        let data = Data(#"{"version":1}"#.utf8)

        switch try URLSessionWebSocketTransport.message(for: data) {
        case .string(let value):
            XCTAssertEqual(value, #"{"version":1}"#)
        case .data:
            XCTFail("The signaling server intentionally rejects binary WebSocket frames")
        @unknown default:
            XCTFail("Unexpected WebSocket message type")
        }
    }
}

private enum TestTransportError: Error { case disconnected }

private struct TransportSnapshot: Sendable {
    let connectedURLs: [URL]
    let sent: [Data]
    let receiveCalls: Int
    let maximumActiveReceives: Int
    let maximumActiveSends: Int
}

private actor TestWebSocketTransport: WebSocketTransport {
    private let blockSends: Bool
    private var connectedURLs: [URL] = []
    private var sent: [Data] = []
    private var incoming: [Result<Data, Error>] = []
    private var receiveContinuation: CheckedContinuation<Data, Error>?
    private var sendContinuations: [CheckedContinuation<Void, Never>] = []
    private var activeReceives = 0
    private var maximumActiveReceives = 0
    private var activeSends = 0
    private var maximumActiveSends = 0
    private var receiveCalls = 0

    init(blockSends: Bool = false) {
        self.blockSends = blockSends
    }

    func connect(to url: URL) async throws {
        connectedURLs.append(url)
    }

    func send(_ data: Data) async throws {
        activeSends += 1
        maximumActiveSends = max(maximumActiveSends, activeSends)
        if blockSends {
            await withCheckedContinuation { continuation in
                sendContinuations.append(continuation)
            }
        }
        sent.append(data)
        activeSends -= 1
    }

    func receive() async throws -> Data {
        receiveCalls += 1
        activeReceives += 1
        maximumActiveReceives = max(maximumActiveReceives, activeReceives)
        defer { activeReceives -= 1 }
        if !incoming.isEmpty {
            return try incoming.removeFirst().get()
        }
        return try await withCheckedThrowingContinuation { continuation in
            receiveContinuation = continuation
        }
    }

    func close() async {
        receiveContinuation?.resume(throwing: CancellationError())
        receiveContinuation = nil
        for continuation in sendContinuations { continuation.resume() }
        sendContinuations.removeAll()
    }

    func enqueue(_ result: Result<Data, Error>) {
        if let continuation = receiveContinuation {
            receiveContinuation = nil
            continuation.resume(with: result)
        } else {
            incoming.append(result)
        }
    }

    func releaseNextSend() {
        guard !sendContinuations.isEmpty else { return }
        sendContinuations.removeFirst().resume()
    }

    func waitUntilActiveSendCount(_ count: Int) async {
        while activeSends != count { await Task.yield() }
    }

    func snapshot() -> TransportSnapshot {
        TransportSnapshot(
            connectedURLs: connectedURLs,
            sent: sent,
            receiveCalls: receiveCalls,
            maximumActiveReceives: maximumActiveReceives,
            maximumActiveSends: maximumActiveSends
        )
    }
}

private func XCTAssertThrowsErrorAsync(
    _ expression: () async throws -> Void,
    file: StaticString = #filePath,
    line: UInt = #line
) async {
    do {
        try await expression()
        XCTFail("Expected error", file: file, line: line)
    } catch {}
}
