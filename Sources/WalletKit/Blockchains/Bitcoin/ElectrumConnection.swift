//
//  ElectrumConnection.swift
//  WalletKit
//

import Foundation
import Network

/// Actor-isolated transport for the Electrum wire protocol:
/// newline-delimited JSON-RPC 2.0 over TCP or TLS, via `Network.framework`
/// (no Combine, per this repo's async/await convention). Correlates
/// responses to requests by `id`; routes `id`-less notifications
/// (subscription pushes) to every subscriber registered with
/// ``addSubscriber(method:onNotification:onFailure:)``.
///
/// Long-lived and shared (see `BitcoinBackendSession`): when the
/// connection fails or the server closes it, every in-flight request and
/// subscriber is failed and the next call opens a fresh connection.
///
/// Deliberately minimal for now: one request in flight per `id` (no
/// batching), and no `server.ping` keepalive loop or `server.version`
/// handshake yet — a follow-up once this is exercised against a real
/// server.
actor ElectrumConnection {
    private enum ConnectionState {
        case idle
        case connecting([CheckedContinuation<Void, Error>])
        case ready
    }

    private struct Subscriber {
        let onNotification: @Sendable (Any) -> Void
        let onFailure: @Sendable (any Error) -> Void
    }

    private let host: NWEndpoint.Host
    private let port: NWEndpoint.Port
    private let useTLS: Bool
    private var connection: NWConnection?
    private var state: ConnectionState = .idle
    private var receiveBuffer = Data()
    private var nextRequestId = 0
    private var pendingResponses: [Int: CheckedContinuation<Any, Error>] = [:]
    private var subscribers: [String: [UUID: Subscriber]] = [:]

    /// - Parameters:
    ///   - host: The Electrum server's hostname.
    ///   - port: The Electrum server's port.
    ///   - useTLS: Whether to connect over TLS (`ssl://`) rather than
    ///     plain TCP (`tcp://`).
    init(host: String, port: UInt16, useTLS: Bool) {
        guard let endpointPort = NWEndpoint.Port(rawValue: port) else {
            preconditionFailure("invalid Electrum port \(port)")
        }

        self.host = NWEndpoint.Host(host)
        self.port = endpointPort
        self.useTLS = useTLS
    }

    deinit {
        connection?.cancel()
    }

    /// Establishes the connection if it isn't already, waiting until it's
    /// ready to send/receive. Safe to call repeatedly — a second call
    /// while connecting joins the same wait; a call once ready returns
    /// immediately; a call after the connection dropped opens a new one.
    func connect() async throws {
        switch state {
        case .ready:
            return
        case .connecting:
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                if case var .connecting(waiters) = state {
                    waiters.append(continuation)
                    state = .connecting(waiters)
                } else {
                    continuation.resume(throwing: BlockchainClientError.transportError(reason: "connection reset"))
                }
            }

            return
        case .idle:
            break
        }

        let connection = NWConnection(host: host, port: port, using: useTLS ? .tls : .tcp)
        let connectionId = ObjectIdentifier(connection)
        self.connection = connection
        receiveBuffer.removeAll()

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            state = .connecting([continuation])
            connection.stateUpdateHandler = { [weak self] newState in
                Task { await self?.handleStateChange(newState, of: connectionId) }
            }

            connection.start(queue: .global(qos: .userInitiated))
        }

        receiveNext()
    }

    /// Sends a single JSON-RPC request and awaits its `result`, as the
    /// raw decoded JSON value (`String`/`NSNumber`/`[Any]`/`[String: Any]`/
    /// `NSNull`) — callers extract the shape they expect.
    ///
    /// - Throws: ``BlockchainClientError`` on a transport failure, or if
    ///   the server returns a JSON-RPC `error` object.
    func call(method: String, params: [Any]) async throws -> Any {
        try await connect()

        guard let connection else {
            throw BlockchainClientError.transportError(reason: "connection reset")
        }

        let id = nextRequestId
        nextRequestId += 1

        let payload: [String: Any] = ["id": id, "method": method, "params": params]
        var framed: Data
        do {
            framed = try JSONSerialization.data(withJSONObject: payload)
        } catch {
            throw BlockchainClientError.decodingFailed(reason: "could not encode request: \(error)")
        }

        framed.append(0x0A)

        return try await withCheckedThrowingContinuation { continuation in
            pendingResponses[id] = continuation
            connection.send(content: framed, completion: .contentProcessed { [weak self] error in
                guard let error else {
                    return
                }

                Task {
                    await self?.failPending(id: id, error: error)
                }
            })
        }
    }

    /// Registers handlers for `id`-less notifications for `method` (a
    /// subscription push, e.g. `blockchain.headers.subscribe`'s follow-up
    /// updates). Every subscriber for a method receives every push.
    ///
    /// When the connection drops, `onFailure` is called once and the
    /// subscriber is removed — the server forgets subscriptions with the
    /// connection, so the caller must subscribe again.
    ///
    /// - Returns: A token for ``removeSubscriber(method:id:)``.
    func addSubscriber(
        method: String,
        onNotification: @escaping @Sendable (Any) -> Void,
        onFailure: @escaping @Sendable (any Error) -> Void
    ) -> UUID {
        let id = UUID()
        subscribers[method, default: [:]][id] = Subscriber(onNotification: onNotification, onFailure: onFailure)
        return id
    }

    /// Removes a subscriber added by
    /// ``addSubscriber(method:onNotification:onFailure:)``.
    func removeSubscriber(method: String, id: UUID) {
        subscribers[method]?[id] = nil
    }

    /// Tears down the connection, failing every request and subscriber
    /// still active. The next call reconnects.
    func disconnect() {
        reset(BlockchainClientError.transportError(reason: "disconnected"))
    }

    // MARK: - Private

    private func isCurrent(_ connectionId: ObjectIdentifier) -> Bool {
        connection.map(ObjectIdentifier.init) == connectionId
    }

    private func handleStateChange(_ newState: NWConnection.State, of connectionId: ObjectIdentifier) {
        // Late callbacks from a connection already replaced by `reset(_:)`.
        guard isCurrent(connectionId) else {
            return
        }

        switch newState {
        case .ready:
            guard case let .connecting(waiters) = state else {
                return
            }

            state = .ready
            for waiter in waiters { waiter.resume() }

        case let .failed(nwError):
            reset(BlockchainClientError.transportError(reason: nwError.localizedDescription))

        case let .waiting(nwError):
            // The server is unreachable; Network.framework would retry
            // indefinitely, leaving callers hanging. Fail now — the next
            // call tries again.
            if case .connecting = state {
                reset(BlockchainClientError.transportError(reason: nwError.localizedDescription))
            }

        case .cancelled:
            reset(BlockchainClientError.transportError(reason: "connection cancelled"))

        default:
            break
        }
    }

    /// Drops the current connection so the next call opens a new one,
    /// failing connect waiters, in-flight requests and subscribers.
    private func reset(_ error: Error) {
        let previous = connection
        connection = nil

        if case let .connecting(waiters) = state {
            for waiter in waiters { waiter.resume(throwing: error) }
        }

        state = .idle
        receiveBuffer.removeAll()
        failAllPending(error)

        let dropped = subscribers.values.flatMap(\.values)
        subscribers.removeAll()
        for subscriber in dropped { subscriber.onFailure(error) }

        previous?.cancel()
    }

    private func failPending(id: Int, error: Error) {
        guard let continuation = pendingResponses.removeValue(forKey: id) else {
            return
        }

        continuation.resume(throwing: BlockchainClientError.transportError(reason: error.localizedDescription))
    }

    private func failAllPending(_ error: Error) {
        for (_, continuation) in pendingResponses {
            continuation.resume(throwing: error)
        }

        pendingResponses.removeAll()
    }

    private func receiveNext() {
        guard let connection else {
            return
        }

        let connectionId = ObjectIdentifier(connection)
        connection.receive(
            minimumIncompleteLength: 1,
            maximumLength: 64 * 1024
        ) { [weak self] data, _, isComplete, error in
            Task { await self?.handleReceive(data: data, isComplete: isComplete, error: error, of: connectionId) }
        }
    }

    private func handleReceive(data: Data?, isComplete: Bool, error: Error?, of connectionId: ObjectIdentifier) {
        guard isCurrent(connectionId) else {
            return
        }

        if let data, !data.isEmpty {
            receiveBuffer.append(data)
            processBufferedLines()
        }

        if let error {
            reset(BlockchainClientError.transportError(reason: error.localizedDescription))
            return
        }

        guard !isComplete else {
            reset(BlockchainClientError.transportError(reason: "connection closed by peer"))
            return
        }

        receiveNext()
    }

    private func processBufferedLines() {
        while let newlineIndex = receiveBuffer.firstIndex(of: 0x0A) {
            let lineData = receiveBuffer[..<newlineIndex]
            receiveBuffer.removeSubrange(...newlineIndex)
            guard !lineData.isEmpty else {
                continue
            }

            handleLine(Data(lineData))
        }
    }

    private func handleLine(_ line: Data) {
        guard let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any] else {
            return
        }

        if let id = object["id"] as? Int {
            guard let continuation = pendingResponses.removeValue(forKey: id) else {
                return
            }

            if let errorObject = object["error"] as? [String: Any] {
                let code = errorObject["code"] as? Int ?? 0
                let message = errorObject["message"] as? String ?? "\(errorObject)"
                continuation.resume(throwing: BlockchainClientError.rpcError(code: code, message: message))
                return
            }

            guard let result = object["result"] else {
                continuation.resume(throwing: BlockchainClientError.invalidResponse(reason: "response missing result"))
                return
            }

            continuation.resume(returning: result)
        } else if let method = object["method"] as? String, let methodSubscribers = subscribers[method] {
            let params = object["params"] ?? [Any]()
            for subscriber in methodSubscribers.values { subscriber.onNotification(params) }
        }
    }
}
