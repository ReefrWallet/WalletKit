//
//  EthereumPKeySigner.swift
//  WalletKit
//
//  Created by Andrey Yurkevich on 17/08/2026.
//  Copyright © 2026 Reefr Wallet. All rights reserved.
//

import Foundation
import WalletKitRust

/// A ``Signer`` backed directly by a software-held ``PrivateKey`` for
/// Ethereum.
public final class EthereumPKeySigner: Signer, MessageSigner {
    public typealias Address = EthereumAddress

    /// The account this signer signs for.
    public let account: Account

    /// EVM chain ID this signer is scoped to (1 = mainnet, 11155111 =
    /// Sepolia, ...) — the value carried by `Blockchain.ethereum(_:)`.
    /// ``sign(transaction:)`` rejects a transaction whose embedded EIP-155
    /// chain ID doesn't match this.
    public let chainId: UInt64

    private let privateKey: PrivateKey
    private let raw: EthereumSignerFfi

    /// Creates a signer for `privateKey`, scoped to `chainId`.
    ///
    /// - Parameters:
    ///   - chainId: The EVM chain ID this signer should operate on.
    ///     Defaults to `1` (Ethereum mainnet).
    ///   - privateKey: The secp256k1 key to sign with.
    ///   - derivationPath: The derivation path `privateKey` was derived at
    ///     (or, for an externally imported key, the path it should be
    ///     treated as belonging to).
    /// - Throws: ``WalletKitError/unsupportedCurve(curve:)`` if
    ///   `privateKey.curve` isn't secp256k1.
    public init(chainId: UInt64 = 1, privateKey: PrivateKey, derivationPath: DerivationPath) throws {
        guard privateKey.curve == .secp256k1 else {
            throw WalletKitError.unsupportedCurve(curve: privateKey.curve)
        }

        self.chainId = chainId
        self.privateKey = privateKey

        raw = EthereumSignerFfi(chainId: chainId)
        account = Account(
            blockchain: .evm(EVMBlockchain(chainId: chainId)),
            derivationPath: derivationPath,
            curve: .secp256k1,
            source: .software,
            publicKey: privateKey.publicKey
        )
    }

    /// Derives the Ethereum address for ``account``'s public key.
    ///
    /// - Returns: The account's Ethereum address.
    public func address() throws -> EthereumAddress {
        try EthereumAddress(publicKey: account.publicKey)
    }

    /// Signs `transaction` — either the `0x02`-prefixed EIP-1559 type-2 signing
    /// preimage from ``UnsignedEIP1559Transaction/signingData`` or the 9-field
    /// EIP-155 RLP blob from ``UnsignedLegacyTransaction/signingData`` — with
    /// ``account``'s key. The transaction type is detected automatically from
    /// the first byte.
    ///
    /// - Parameter transaction: Unsigned transaction bytes, as returned by
    ///   ``EthereumTransactionBuilder/buildTransfer(sender:recipient:amount:token:options:)``.
    /// - Returns: The signed transaction ready to broadcast via
    ///   ``EthereumRPCClient/broadcast(_:)``.
    /// - Throws: ``WalletKitError/signingFailed(reason:)`` if `transaction`
    ///   is malformed or its embedded chain ID doesn't match ``chainId``.
    public func sign(transaction: Data) async throws -> Data {
        if transaction.first == 0x02 {
            return try remappingWalletKitError {
                try raw.signEip1559(signingData: transaction, privateKey: privateKey.raw)
            }
        }
        return try remappingWalletKitError { try raw.sign(signingData: transaction, privateKey: privateKey.raw) }
    }

    /// Signs `message` — an EIP-191 personal message or an EIP-712
    /// typed-data payload — with ``account``'s key, returning the 65-byte
    /// `r ‖ s ‖ v` signature (legacy 27/28 `v`, no EIP-155 folding).
    ///
    /// - Throws: ``WalletKitError/unsupportedFeature`` if `message` isn't
    ///   an Ethereum message kind, or ``WalletKitError/signingFailed(reason:)``
    ///   if `message`'s typed-data JSON is malformed.
    public func sign(message: SignableMessage) async throws -> Data {
        let digest: Data
        switch message {
        case .ethereumPersonal(let data):
            digest = ethereumPersonalMessageHash(message: data)
        case .ethereumTypedData(let json):
            digest = try remappingWalletKitError { try ethereumTypedDataHash(json: json) }
        }
        return try remappingWalletKitError { try raw.signDigest(digest: digest, privateKey: privateKey.raw) }
    }
}
