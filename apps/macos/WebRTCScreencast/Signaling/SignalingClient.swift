import Foundation

protocol WebSocketTransport: Sendable {
    func connect(to url: URL) async throws
    func send(_ data: Data) async throws
    func receive() async throws -> Data
    func close() async
}

enum WebSocketTransportError: Error, Equatable {
    case invalidURLScheme
    case notConnected
    case unsupportedMessage
}

actor URLSessionWebSocketTransport: WebSocketTransport {
    private let session: URLSession
    private var task: URLSessionWebSocketTask?

    init(configuration: URLSessionConfiguration = .default) {
        session = URLSession(configuration: configuration)
    }

    nonisolated func validate(url: URL) throws {
        guard let scheme = url.scheme?.lowercased(), scheme == "ws" || scheme == "wss" else {
            throw WebSocketTransportError.invalidURLScheme
        }
    }

    func connect(to url: URL) async throws {
        try validate(url: url)
        guard task == nil else { return }
        let webSocketTask = session.webSocketTask(with: url)
        task = webSocketTask
        webSocketTask.resume()
    }

    func send(_ data: Data) async throws {
        guard let task else { throw WebSocketTransportError.notConnected }
        try await task.send(.data(data))
    }

    func receive() async throws -> Data {
        guard let task else { throw WebSocketTransportError.notConnected }
        switch try await task.receive() {
        case let .data(data):
            return data
        case let .string(string):
            return Data(string.utf8)
        @unknown default:
            throw WebSocketTransportError.unsupportedMessage
        }
    }

    func close() async {
        task?.cancel(with: .normalClosure, reason: nil)
        task = nil
    }
}

enum SignalingClientError: Error, Equatable {
    case alreadyConnected
    case notConnected
    case wrongRole(expected: CastingRole)
    case closed
}

enum SignalingEvent: Equatable, Sendable {
    case message(SignalingEnvelope)
}

actor SignalingClient {
    private enum Lifecycle: Equatable {
        case idle
        case connected(CastingRole)
        case closed
    }

    private let transport: any WebSocketTransport
    private let messageID: @Sendable () -> String
    private let eventStream: AsyncThrowingStream<SignalingEvent, Error>
    private let eventContinuation: AsyncThrowingStream<SignalingEvent, Error>.Continuation
    private var lifecycle: Lifecycle = .idle
    private var readerTask: Task<Void, Never>?
    private var sendTail: Task<Void, Error>?

    init(
        transport: any WebSocketTransport = URLSessionWebSocketTransport(),
        messageID: @escaping @Sendable () -> String = { UUID().uuidString }
    ) {
        self.transport = transport
        self.messageID = messageID
        let pair = AsyncThrowingStream<SignalingEvent, Error>.makeStream()
        eventStream = pair.stream
        eventContinuation = pair.continuation
    }

    func events() -> AsyncThrowingStream<SignalingEvent, Error> {
        eventStream
    }

    func connect(url: URL, role: CastingRole) async throws {
        switch lifecycle {
        case .idle:
            break
        case .connected:
            throw SignalingClientError.alreadyConnected
        case .closed:
            throw SignalingClientError.closed
        }
        try await transport.connect(to: url)
        lifecycle = .connected(role)
        readerTask = Task { [weak self] in
            await self?.readLoop()
        }
    }

    func registerReceiver() async throws {
        try require(role: .receiver)
        try await send(.receiverRegister)
    }

    func join(code: String) async throws {
        try require(role: .sender)
        try await send(.senderJoin(pairingCode: try PairingCode.normalize(code)))
    }

    func send(_ payload: SignalingPayload) async throws {
        guard case .connected = lifecycle else {
            throw lifecycle == .closed ? SignalingClientError.closed : SignalingClientError.notConnected
        }
        let data = try SignalingCodec.encode(SignalingEnvelope(messageID: messageID(), payload: payload))
        let previous = sendTail
        let transport = self.transport
        let next = Task {
            if let previous { _ = try? await previous.value }
            try Task.checkCancellation()
            try await transport.send(data)
        }
        sendTail = next
        try await next.value
    }

    func close() async {
        guard lifecycle != .closed else { return }
        lifecycle = .closed
        readerTask?.cancel()
        sendTail?.cancel()
        await transport.close()
        eventContinuation.finish()
        readerTask = nil
        sendTail = nil
    }

    private func require(role expected: CastingRole) throws {
        guard case let .connected(actual) = lifecycle else {
            throw lifecycle == .closed ? SignalingClientError.closed : SignalingClientError.notConnected
        }
        guard actual == expected else { throw SignalingClientError.wrongRole(expected: expected) }
    }

    private func readLoop() async {
        do {
            while !Task.isCancelled {
                let data = try await transport.receive()
                let message = try SignalingCodec.decode(data)
                eventContinuation.yield(.message(message))
            }
        } catch is CancellationError {
            return
        } catch {
            guard lifecycle != .closed else { return }
            lifecycle = .closed
            eventContinuation.finish(throwing: error)
            await transport.close()
        }
    }
}
