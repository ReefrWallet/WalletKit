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
/// (subscription pushes) to per-method handlers registered with
/// ``onNotification(method:handler:)``.
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
        case failed(Error)
    }

    private let connection: NWConnection
    private var state: ConnectionState = .idle
    private var receiveBuffer = Data()
    private var nextRequestId = 0
    private var pendingResponses: [Int: CheckedContinuation<Any, Error>] = [:]
    private var notificationHandlers: [String: (Any) -> Void] = [:]

    /// - Parameters:
    ///   - host: The Electrum server's hostname.
    ///   - port: The Electrum server's port.
    ///   - useTLS: Whether to connect over TLS (`ssl://`) rather than
    ///     plain TCP (`tcp://`).
    init(host: String, port: UInt16, useTLS: Bool) {
        guard let endpointPort = NWEndpoint.Port(rawValue: port) else {
            preconditionFailure("invalid Electrum port \(port)")
        }

        connection = NWConnection(host: NWEndpoint.Host(host), port: endpointPort, using: useTLS ? .tls : .tcp)
    }

    deinit {
        connection.cancel()
    }

    /// Establishes the connection if it isn't already, waiting until it's
    /// ready to send/receive. Safe to call repeatedly — a second call
    /// while connecting joins the same wait; a call once ready returns
    /// immediately.
    func connect() async throws {
        switch state {
        case .ready:
            return
        case let .failed(error):
            throw error
        case .connecting:
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                if case var .connecting(waiters) = state {
                    waiters.append(continuation)
                    state = .connecting(waiters)
                }
            }

            return
        case .idle:
            break
        }

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            state = .connecting([continuation])
            connection.stateUpdateHandler = { [weak self] newState in
                guard let self else {
                    return
                }

                Task { await self.handleStateChange(newState) }
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

    /// Registers `handler` for `id`-less notifications for `method` (a
    /// subscription push, e.g. `blockchain.headers.subscribe`'s
    /// follow-up updates). Replaces any existing handler for the same
    /// method.
    func onNotification(method: String, handler: @escaping (Any) -> Void) {
        notificationHandlers[method] = handler
    }

    /// Tears down the connection, failing every request still in flight.
    func disconnect() {
        connection.cancel()
        state = .idle
        failAllPending(BlockchainClientError.transportError(reason: "disconnected"))
    }

    // MARK: - Private

    private func handleStateChange(_ newState: NWConnection.State) {
        switch newState {
        case .ready:
            guard case let .connecting(waiters) = state else {
                return
            }

            state = .ready
            for waiter in waiters { waiter.resume() }

        case let .failed(nwError):
            let mapped = BlockchainClientError.transportError(reason: nwError.localizedDescription)
            if case let .connecting(waiters) = state {
                for waiter in waiters { waiter.resume(throwing: mapped) }
            }

            state = .failed(mapped)
            failAllPending(mapped)

        case .cancelled:
            let error = BlockchainClientError.transportError(reason: "connection cancelled")
            if case let .connecting(waiters) = state {
                for waiter in waiters { waiter.resume(throwing: error) }
            }

            state = .idle

        default:
            break
        }
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
        connection.receive(
            minimumIncompleteLength: 1,
            maximumLength: 64 * 1024
        ) { [weak self] data, _, isComplete, error in
            Task { await self?.handleReceive(data: data, isComplete: isComplete, error: error) }
        }
    }

    private func handleReceive(data: Data?, isComplete: Bool, error: Error?) {
        if let data, !data.isEmpty {
            receiveBuffer.append(data)
            processBufferedLines()
        }

        if let error {
            state = .failed(BlockchainClientError.transportError(reason: error.localizedDescription))
            failAllPending(BlockchainClientError.transportError(reason: error.localizedDescription))
            return
        }

        guard !isComplete else {
            let closedError = BlockchainClientError.transportError(reason: "connection closed by peer")
            state = .failed(closedError)
            failAllPending(closedError)
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
        } else if let method = object["method"] as? String, let handler = notificationHandlers[method] {
            handler(object["params"] ?? [Any]())
        }
    }
}
