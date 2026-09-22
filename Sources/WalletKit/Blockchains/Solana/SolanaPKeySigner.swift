//
//  SolanaPKeySigner.swift
//  WalletKit
//
//  Created by Andrey Yurkevich on 21/09/2026.
//  Copyright © 2026 Reefr Wallet. All rights reserved.
//

import Foundation

/// A ``Signer`` backed directly by a software-held ed25519 ``PrivateKey``,
/// for Solana.
///
/// Signs the raw serialized message bytes carried in the
/// ``SolanaUnsignedTransaction`` envelope directly — Solana has no
/// separate signing-hash step, and ed25519 signing hashes internally.
public final class SolanaPKeySigner: Signer {
    public typealias Address = SolanaAddress

    /// The account this signer signs for.
    public let account: WKAccount

    private let privateKey: PrivateKey

    /// Creates a signer for `privateKey`, scoped to `network`.
    ///
    /// - Parameters:
    ///   - network: Which Solana network this signer targets. Defaults to
    ///     `.mainnet`.
    ///   - privateKey: The ed25519 key to sign with.
    ///   - derivationPath: The derivation path `privateKey` was derived
    ///     at (or, for an externally imported key, the path it should be
    ///     treated as belonging to).
    /// - Throws: ``WalletKitError/unsupportedCurve(curve:)`` if
    ///   `privateKey.curve != .ed25519`.
    public init(network: SolanaNetwork = .mainnet, privateKey: PrivateKey, derivationPath: DerivationPath) throws {
        guard privateKey.curve == .ed25519 else {
            throw WalletKitError.unsupportedCurve(curve: privateKey.curve)
        }
        self.privateKey = privateKey
        account = WKAccount(
            blockchain: .solana(network),
            derivationPath: derivationPath,
            curve: .ed25519,
            source: .software,
            publicKey: privateKey.publicKey
        )
    }

    /// Derives the Solana address for ``account``'s public key.
    public func address() throws -> SolanaAddress {
        try SolanaAddress(publicKey: account.publicKey)
    }

    /// Signs the message bytes inside `transaction`'s
    /// ``SolanaUnsignedTransaction`` envelope with ``account``'s key.
    ///
    /// - Parameter transaction: The JSON envelope produced by
    ///   ``SolanaTransactionBuilder``.
    /// - Returns: The raw 64-byte ed25519 signature.
    public func sign(transaction: Data) async throws -> Data {
        let envelope = try JSONDecoder().decode(SolanaUnsignedTransaction.self, from: transaction)
        return try privateKey.sign(message: envelope.message)
    }
}
