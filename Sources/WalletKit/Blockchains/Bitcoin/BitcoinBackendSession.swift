//
//  BitcoinBackendSession.swift
//  WalletKit
//
//  Copyright © 2026 Reefr Wallet. All rights reserved.
//

import Foundation
import Synchronization

/// Long-lived state for one Bitcoin backend endpoint: the backend itself
/// (for Electrum, its TCP/TLS connection) and the per-account address
/// resolvers whose gap-limit discovery is expensive to repeat.
///
/// ``BitcoinClient``s created for the same Electrum server or Esplora URL
/// share one session through ``electrum(host:port:useTLS:)`` /
/// ``esplora(endpoint:session:)``, so callers can create a new client per
/// call without reconnecting or rediscovering addresses.
final class BitcoinBackendSession: Sendable {
    private enum Endpoint: Hashable {
        case electrum(host: String, port: UInt16, useTLS: Bool)
        case esplora(endpoint: URL, session: ObjectIdentifier)
    }

    private static let sessions = Mutex<[Endpoint: BitcoinBackendSession]>([:])

    let backend: any BitcoinBackend
    private let resolvers = Mutex<[String: BitcoinAddressResolver]>([:])

    /// Creates an unshared session around `backend` — for injecting a test
    /// double.
    init(backend: any BitcoinBackend) {
        self.backend = backend
    }

    /// The shared session for the Electrum server at `host:port`.
    static func electrum(host: String, port: UInt16, useTLS: Bool) -> BitcoinBackendSession {
        shared(for: .electrum(host: host, port: port, useTLS: useTLS)) {
            ElectrumBackend(host: host, port: port, useTLS: useTLS)
        }
    }

    /// The shared session for the Esplora API at `endpoint`, reached via
    /// `session`.
    static func esplora(endpoint: URL, session: URLSession) -> BitcoinBackendSession {
        shared(for: .esplora(endpoint: endpoint, session: ObjectIdentifier(session))) {
            EsploraBackend(endpoint: endpoint, session: session)
        }
    }

    private static func shared(
        for endpoint: Endpoint,
        makeBackend: () -> any BitcoinBackend
    ) -> BitcoinBackendSession {
        sessions.withLock { sessions in
            if let existing = sessions[endpoint] {
                return existing
            }

            let session = BitcoinBackendSession(backend: makeBackend())
            sessions[endpoint] = session
            return session
        }
    }

    /// The resolver for `descriptor`, creating one on first use. Keyed by
    /// network as well as descriptor text, since a `tpub` descriptor reads
    /// the same on testnet, signet and regtest but derives different
    /// addresses on each.
    func resolver(for descriptor: BitcoinDescriptor) -> BitcoinAddressResolver {
        let key = "\(descriptor.network):\(descriptor.string)"
        return resolvers.withLock { resolvers in
            if let existing = resolvers[key] {
                return existing
            }

            let resolver = BitcoinAddressResolver(descriptor: descriptor, backend: backend)
            resolvers[key] = resolver
            return resolver
        }
    }
}
