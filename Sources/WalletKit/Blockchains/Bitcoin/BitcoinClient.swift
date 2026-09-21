//
//  BitcoinClient.swift
//  WalletKit
//

import Foundation

/// The ``BlockchainClientProtocol`` conformer for Bitcoin. Holds one
/// ``BitcoinBackend`` (Electrum or Esplora) and maintains one
/// ``BitcoinAddressResolver`` per distinct account descriptor it's asked
/// about, since — unlike Ethereum/Sui, where one address is one account —
/// a Bitcoin account resolves to many addresses. This mirrors
/// `BlockchainClientProvider` caching one client per `(blockchain,
/// rpcURL, backend)` triple shared by every account on that network, not
/// one client per account: `owner`/`sender` are passed per call, exactly
/// as `SuiGRPCClient`/`EthereumRPCClient` already do.
public actor BitcoinClient {
    /// Immutable and `Sendable`, so safe to read without hopping onto
    /// the actor — used by `nonisolated` protocol witnesses
    /// (`isSupported(_:)`, `transactionHeads(_:)`) and by
    /// ``BitcoinTransactionBuilder``.
    nonisolated let backend: any BitcoinBackend
    private var resolvers: [String: BitcoinAddressResolver] = [:]

    /// Creates a client backed by Electrum at `host:port`.
    public init(electrumHost host: String, port: UInt16, useTLS: Bool) {
        backend = ElectrumBackend(host: host, port: port, useTLS: useTLS)
    }

    /// Creates a client backed by an Esplora-compatible REST API at
    /// `endpoint`.
    public init(esploraEndpoint endpoint: URL, session: URLSession = .shared) {
        backend = EsploraBackend(endpoint: endpoint, session: session)
    }

    /// Creates a client backed directly by `backend` — not part of the
    /// public API; for injecting a test double.
    init(backend: any BitcoinBackend) {
        self.backend = backend
    }

    /// The cached resolver for `descriptor`, creating one on first use.
    func resolver(for descriptor: BitcoinDescriptor) -> BitcoinAddressResolver {
        if let existing = resolvers[descriptor.string] {
            return existing
        }
        let resolver = BitcoinAddressResolver(descriptor: descriptor, backend: backend)
        resolvers[descriptor.string] = resolver
        return resolver
    }
}
