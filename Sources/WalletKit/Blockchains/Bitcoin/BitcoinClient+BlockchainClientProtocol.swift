//
//  BitcoinClient+BlockchainClientProtocol.swift
//  WalletKit
//

import BigInt
import Foundation
import WalletKitRust

/// ``BlockchainClientProtocol`` conformance for ``BitcoinClient``.
///
/// `Address` is inferred as ``BitcoinDescriptor``. Bitcoin has exactly one
/// asset, so every token-parameterized method throws
/// ``WalletKitError/unsupportedFeature`` — matching `isSupported(_:)`
/// reporting `.multipleBalances`/`.allBalances` as unsupported.
extension BitcoinClient: BlockchainClientProtocol {
    public func getAllBalances(_ owner: BitcoinDescriptor) async throws -> [String: BigUInt] {
        throw WalletKitError.unsupportedFeature
    }

    public func getBalances(_ owner: BitcoinDescriptor, tokens: [String]) async throws -> [String: BigUInt] {
        throw WalletKitError.unsupportedFeature
    }

    public func getBalance(_ owner: BitcoinDescriptor, token: String) async throws -> BigUInt {
        throw WalletKitError.unsupportedFeature
    }

    /// Sums confirmed + unconfirmed balance (sats) across every
    /// discovered, used address on both chains. Unconfirmed can be
    /// negative (a pending spend not yet confirmed); the total is
    /// floored at zero rather than ever reporting a negative balance.
    public func getNativeBalance(_ owner: BitcoinDescriptor) async throws -> BigUInt {
        let resolver = resolver(for: owner)
        var total: Int64 = 0
        for derived in try await resolver.allAddresses() where derived.isUsed {
            let (confirmed, unconfirmed) = try await backend.balance(of: derived.address)
            total += Int64(confirmed) + unconfirmed
        }

        return BigUInt(max(0, total))
    }

    public func getTokenInfo(_ token: String?) async throws -> TokenInfo {
        guard token == nil else {
            throw WalletKitError.unsupportedFeature
        }

        return .bitcoin
    }

    public func getTokenPrice(_ token: String?) async throws -> Decimal {
        throw WalletKitError.internalError(message: "Not Implemented")
    }

    public func isActiveAccount(_ owner: BitcoinDescriptor) async throws -> Bool {
        let resolver = resolver(for: owner)
        return try await resolver.allAddresses().contains { $0.isUsed }
    }

    public nonisolated func isSupported(_ feature: BlockchainClientFeature) -> Bool {
        switch feature {
        case .multipleBalances: false
        case .allBalances: false
        case .transactionHistory: true
        case .transactionSubscription: backend is ElectrumBackend
        }
    }

    /// Broadcasts a signed transaction.
    ///
    /// `signature` carries the finalized, consensus-serialized raw
    /// transaction (from `BitcoinSignerFfi.finalizePsbt`); `transaction`
    /// (the unsigned PSBT) is unused — matching Ethereum's convention of
    /// putting the complete signed payload in `signature`.
    public func broadcast(transaction: Data, signature: Data) async throws -> String {
        try await backend.broadcast(rawTransaction: signature)
    }
}
