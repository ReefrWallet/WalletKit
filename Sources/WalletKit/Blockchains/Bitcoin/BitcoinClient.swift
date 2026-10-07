//
//  BitcoinClient.swift
//  WalletKit
//

import Foundation

/// The ``BlockchainClientProtocol`` conformer for Bitcoin. Talks to one
/// Electrum or Esplora backend and resolves each account descriptor to
/// its addresses. A Bitcoin account can resolve to many addresses.
///
/// Clients created for the same endpoint share a ``BitcoinBackendSession``
/// — one Electrum connection and one address resolver per descriptor — so
/// creating a client is cheap and doesn't repeat address discovery.
public actor BitcoinClient {
    /// The shared connection and resolver state for this client's endpoint.
    private nonisolated let session: BitcoinBackendSession

    /// Immutable and `Sendable`, so safe to read without hopping onto
    /// the actor — used by `nonisolated` protocol witnesses
    /// (`isSupported(_:)`, `transactionHeads(_:)`) and by
    /// ``BitcoinTransactionBuilder``.
    nonisolated var backend: any BitcoinBackend {
        session.backend
    }

    /// The network this client's backend serves, used by
    /// ``makeAddress(_:)`` to parse address strings. `nil` falls back to
    /// ``BitcoinDescriptor/init(string:)``'s network inference.
    public nonisolated let network: BitcoinNetwork?

    /// Creates a client backed by Electrum at `host:port`, sharing its
    /// connection with every other client for the same server.
    public init(electrumHost host: String, port: UInt16, useTLS: Bool, network: BitcoinNetwork? = nil) {
        session = .electrum(host: host, port: port, useTLS: useTLS)
        self.network = network
    }

    /// Creates a client backed by an Esplora-compatible REST API at
    /// `endpoint`, sharing discovered addresses with every other client
    /// for the same endpoint and `session`.
    public init(esploraEndpoint endpoint: URL, session: URLSession = .shared, network: BitcoinNetwork? = nil) {
        self.session = .esplora(endpoint: endpoint, session: session)
        self.network = network
    }

    /// Creates a client backed directly by `backend`, with its own unshared
    /// state — not part of the public API; for injecting a test double.
    init(backend: any BitcoinBackend, network: BitcoinNetwork? = nil) {
        session = BitcoinBackendSession(backend: backend)
        self.network = network
    }

    /// Parses either form a String-addressed caller can hand over: a full
    /// account descriptor (the sender, e.g.
    /// `wpkh([fp/84'/1'/0']xpub.../<0;1>/*)`) or, when ``network`` is
    /// known, a plain address (the recipient, as typed into the Send form —
    /// ``BitcoinDescriptor/init(string:network:)`` only accepts descriptor
    /// syntax and throws on a bare address).
    ///
    /// - Throws: ``WalletKitError/invalidAddress(reason:)``.
    public nonisolated func makeAddress(_ string: String) throws -> BitcoinDescriptor {
        guard let network else {
            return try BitcoinDescriptor(string: string)
        }

        if let descriptor = try? BitcoinDescriptor(string: string, network: network) {
            return descriptor
        }

        return try BitcoinDescriptor(address: string, network: network)
    }

    /// The shared resolver for `descriptor`, creating one on first use.
    func resolver(for descriptor: BitcoinDescriptor) -> BitcoinAddressResolver {
        session.resolver(for: descriptor)
    }
}
