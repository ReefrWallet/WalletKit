//
//  SuiPKeySigner.swift
//  WalletKit
//
//  Created by Andrey Yurkevich on 17/08/2026.
//  Copyright © 2026 Reefr Wallet. All rights reserved.
//

import Foundation
import WalletKitRust

/// A ``Signer`` backed directly by a software-held ``PrivateKey``, for Sui.
/// Backed by `SuiSignerFfi` (blake2-based).
public final class SuiPKeySigner: MessageSigner {
    public typealias Address = SuiAddress

    /// The account this signer signs for.
    public let account: Account

    /// Which signature scheme this signer's account uses — the `Curve`
    /// carried by `Blockchain.sui(_:)`.
    public let curve: Curve

    private let privateKey: PrivateKey
    private let raw: SuiSignerFfi

    /// Creates a signer for `privateKey`, scoped to `curve` and `network`.
    ///
    /// - Parameters:
    ///   - curve: Which signature scheme this signer's account uses.
    ///     Defaults to `.ed25519`, Sui's standard scheme.
    ///   - network: Which Sui network this signer targets.
    ///     Defaults to `.mainnet`.
    ///   - privateKey: The key to sign with; must match `curve`.
    ///   - derivationPath: The derivation path `privateKey` was derived at
    ///     (or, for an externally imported key, the path it should be
    ///     treated as belonging to).
    /// - Throws: ``WalletKitError/unsupportedCurve(curve:)`` if
    ///   `privateKey.curve != curve`.
    public init(
        curve: Curve = .ed25519,
        network: SuiNetwork = .mainnet,
        privateKey: PrivateKey,
        derivationPath: DerivationPath
    ) throws {
        guard privateKey.curve == curve else {
            throw WalletKitError.unsupportedCurve(curve: privateKey.curve)
        }

        self.curve = curve
        self.privateKey = privateKey
        raw = SuiSignerFfi(curve: curve.raw)
        account = Account(
            blockchain: .sui(network),
            derivationPath: derivationPath,
            curve: curve,
            source: .software,
            publicKey: privateKey.publicKey
        )
    }

    /// Derives the Sui address for ``account``'s public key.
    ///
    /// - Returns: The account's Sui address.
    public func address() throws -> SuiAddress {
        try SuiAddress(publicKey: account.publicKey, curve: curve)
    }

    /// Signs `transaction` — raw, un-intent-prefixed BCS-encoded
    /// `TransactionData` bytes for a Programmable Transaction Block (e.g.
    /// from `sui client ptb --serialize-unsigned-transaction`) — with
    /// ``account``'s key, returning Sui's serialized signature
    /// (`flag || signature || public key`) ready to broadcast alongside
    /// `transaction`.
    ///
    /// - Parameter transaction: The raw BCS-encoded `TransactionData` bytes
    ///   to sign.
    /// - Returns: Sui's serialized signature, ready to broadcast alongside
    ///   `transaction`.
    public func sign(transaction: Data) async throws -> Data {
        try remappingWalletKitError { try raw.sign(transactionData: transaction, privateKey: privateKey.raw) }
    }

    /// Signs `message` — a Sui personal message (`sui:signPersonalMessage`)
    /// — with ``account``'s key, returning Sui's serialized signature
    /// (`flag || signature || public key`), same encoding as
    /// ``sign(transaction:)``. Uses a distinct signing intent
    /// (`PersonalMessage`, not `TransactionData`), so this signature can
    /// never be replayed as a transaction signature or vice versa.
    ///
    /// - Throws: ``WalletKitError/unsupportedFeature`` if `message` isn't
    ///   ``SignableMessage/suiPersonal(_:)``.
    public func sign(message: SignableMessage) async throws -> Data {
        guard case let .suiPersonal(data) = message else {
            throw WalletKitError.unsupportedFeature
        }

        return try remappingWalletKitError {
            try raw.signPersonalMessage(message: data, privateKey: privateKey.raw)
        }
    }
}
