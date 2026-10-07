//
//  SuiGRPCClientPool.swift
//  WalletKit
//
//  Copyright © 2026 Reefr Wallet. All rights reserved.
//

import GRPCCore
import GRPCNIOTransportHTTP2Posix
import Synchronization

/// Long-lived gRPC clients, one per Sui full-node endpoint, shared by every
/// ``SuiGRPCClient`` value that targets it.
///
/// ``SuiGRPCClient`` is a cheap value type that callers create freely; the
/// HTTP/2 connection lives here instead, so RPCs reuse it rather than paying
/// a TCP + TLS handshake each. The transport reconnects on its own after a
/// dropped connection, so an entry stays usable for the process lifetime.
final class SuiGRPCClientPool: Sendable {
    typealias Client = GRPCClient<HTTP2ClientTransport.Posix>

    struct Endpoint: Hashable, Sendable {
        let host: String
        let port: Int
        let useTLS: Bool
    }

    /// The process-wide pool used by ``SuiGRPCClient``.
    static let shared = SuiGRPCClientPool()

    private let clients = Mutex<[Endpoint: Client]>([:])

    /// Returns the running client for `endpoint`, creating and starting one
    /// on first use.
    ///
    /// - Throws: ``BlockchainClientError/transportError(reason:)`` if the
    ///   transport can't be created.
    func client(for endpoint: Endpoint) throws -> Client {
        try clients.withLock { clients in
            if let existing = clients[endpoint] {
                return existing
            }

            let transport: HTTP2ClientTransport.Posix
            do {
                transport = try HTTP2ClientTransport.Posix(
                    target: .dns(host: endpoint.host, port: endpoint.port),
                    transportSecurity: endpoint.useTLS ? .tls : .plaintext
                )
            } catch {
                throw BlockchainClientError.transportError(reason: error.localizedDescription)
            }

            let client = Client(transport: transport)
            clients[endpoint] = client

            // `runConnections()` only returns once the client shuts down;
            // drop the entry then so the next caller starts a fresh one.
            Task.detached { [weak self] in
                try? await client.runConnections()
                self?.remove(client, for: endpoint)
            }

            return client
        }
    }

    private func remove(_ client: Client, for endpoint: Endpoint) {
        clients.withLock { clients in
            if clients[endpoint] === client {
                clients[endpoint] = nil
            }
        }
    }
}
