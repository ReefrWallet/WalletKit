//
//  EthereumTrezorSigner.swift
//  WalletKit
//
//  Created by Andrey Yurkevich on 17/08/2026.
//  Copyright © 2026 Reefr Wallet. All rights reserved.
//

import Foundation
import WalletKitRust

/// A ``Signer`` backed by a connected Trezor ``HardwareDevice``, for
/// Ethereum. This type handles decoding the caller-supplied EIP-155
/// signing data into the structured fields the device's trusted screen
/// displays (``signTx(from:)``) and re-assembling the device's returned
/// signature into a broadcastable transaction
/// (``signedTransaction(_:signature:)``). ``sign(transaction:)`` presents
/// the decoded transaction on the device's trusted screen and returns its
/// signature after the person confirms it.
public final class EthereumTrezorSigner: Signer, MessageSigner {
    public typealias Address = EthereumAddress

    /// The account this signer signs for.
    public let account: Account

    /// EVM chain ID this signer is scoped to (1 = mainnet, 11155111 =
    /// Sepolia, ...) — the value carried by `Blockchain.ethereum(_:)`.
    public let chainId: UInt64

    private let device: HardwareDevice
    private let raw: EthereumSignerFfi

    /// Creates a signer scoped to `chainId`, reading the public key at
    /// `derivationPath` off `device` to build ``account``.
    ///
    /// - Parameters:
    ///   - chainId: The EVM chain ID this signer should operate on.
    ///     Defaults to `1` (Ethereum mainnet).
    ///   - device: The connected Trezor to sign with.
    ///   - derivationPath: The derivation path to read the account's
    ///     public key at.
    /// - Throws: ``WalletKitError/deviceDisconnected`` if `device` isn't
    ///   connected.
    public init(chainId: UInt64 = 1, device: HardwareDevice, derivationPath: DerivationPath) async throws {
        let publicKey = try await device.publicKey(path: derivationPath, curve: .secp256k1)
        self.chainId = chainId
        self.device = device
        raw = EthereumSignerFfi(chainId: chainId)
        account = Account(
            blockchain: .evm(EVMBlockchain(chainId: chainId)),
            derivationPath: derivationPath,
            curve: .secp256k1,
            source: device.source,
            publicKey: publicKey
        )
    }

    /// Derives the Ethereum address for ``account``'s public key.
    public func address() throws -> EthereumAddress {
        try EthereumAddress(publicKey: account.publicKey)
    }

    /// Decodes `transaction` into the structured fields Trezor's
    /// `EthereumSignTx` message carries, for the device's trusted screen to
    /// display.
    ///
    /// - Parameter transaction: The 9-field EIP-155 RLP-encoded unsigned
    ///   transaction blob.
    /// - Throws: ``WalletKitError/signingFailed(reason:)`` if `transaction`
    ///   isn't well-formed 9-field EIP-155 RLP or its embedded chain ID
    ///   doesn't match ``chainId``.
    public func signTx(from transaction: Data) throws -> EthereumSignTx {
        try remappingWalletKitError { try EthereumSignTx(raw: try raw.decodeSigningData(signingData: transaction)) }
    }

    /// Assembles `transaction` and a device-produced `signature` into a
    /// broadcastable signed transaction.
    ///
    /// - Parameters:
    ///   - transaction: The same unsigned transaction blob passed to
    ///     ``signTx(from:)``.
    ///   - signature: The signature the device returned for it.
    /// - Returns: The RLP-encoded signed transaction, ready to broadcast.
    /// - Throws: ``WalletKitError/signingFailed(reason:)`` if `signature`
    ///   doesn't match ``chainId``'s expected EIP-155 `v`, or its `r`/`s`
    ///   aren't 32 bytes each.
    public func signedTransaction(_ transaction: Data, signature: EthereumSignature) throws -> Data {
        try remappingWalletKitError { try raw.encodeSigned(signingData: transaction, signature: signature.raw) }
    }

    /// Decodes `transaction` — a `0x02`-prefixed EIP-1559 type-2 signing
    /// preimage — into the structured fields Trezor's `EthereumSignTxEIP1559`
    /// message carries.
    ///
    /// - Throws: ``WalletKitError/signingFailed(reason:)`` if `transaction`
    ///   doesn't start with `0x02` or isn't a valid EIP-1559 preimage.
    public func signTxEIP1559(from transaction: Data) throws -> EthereumEIP1559SignTx {
        try remappingWalletKitError {
            try EthereumEIP1559SignTx(raw: try raw.decodeEip1559SigningData(signingData: transaction))
        }
    }

    /// Assembles `transaction` and a device-produced EIP-1559 `signature`
    /// into a broadcastable signed type-2 transaction.
    ///
    /// - Throws: ``WalletKitError/signingFailed(reason:)`` if `signature.yParity`
    ///   isn't 0/1, or `r`/`s` aren't 32 bytes each.
    public func signedTransactionEIP1559(_ transaction: Data, signature: EthereumEIP1559Signature) throws -> Data {
        try remappingWalletKitError {
            try raw.encodeSignedEip1559(signingData: transaction, signature: signature.raw)
        }
    }

    /// Signs `transaction` on the connected Trezor, showing its decoded
    /// fields on the device's trusted screen for the user to confirm.
    /// The transaction type is detected from the first byte: `0x02` routes
    /// through the EIP-1559 `EthereumSignTxEIP1559` message; anything else
    /// uses the legacy `EthereumSignTx` path.
    ///
    /// - Parameter transaction: Unsigned transaction bytes, as returned by
    ///   ``EthereumTransactionBuilder/buildTransfer(sender:recipient:amount:token:options:)``.
    /// - Returns: The signed transaction ready to broadcast.
    /// - Throws: ``WalletKitError/signingFailed(reason:)`` if `transaction`
    ///   is malformed or its embedded chain ID doesn't match ``chainId``,
    ///   ``WalletKitError/deviceDisconnected`` if the device has gone away,
    ///   or ``WalletKitError/userCancelled``/
    ///   ``WalletKitError/userRejectedOnDevice`` if the user backs out of
    ///   a PIN/passphrase/confirmation prompt.
    public func sign(transaction: Data) async throws -> Data {
        guard device.isConnected else {
            throw WalletKitError.deviceDisconnected
        }

        if transaction.first == 0x02 {
            // EIP-1559 path
            let tx = try remappingWalletKitError { try raw.decodeEip1559SigningData(signingData: transaction) }
            let ffiSignature = try await remappingWalletKitError {
                try await device.raw.ethereumSignTxEip1559(path: account.derivationPath.raw, tx: tx)
            }

            let signature = EthereumEIP1559Signature(
                yParity: ffiSignature.yParity,
                r: ffiSignature.r,
                s: ffiSignature.s
            )

            return try signedTransactionEIP1559(transaction, signature: signature)
        }

        // Legacy EIP-155 path
        let tx = try remappingWalletKitError { try raw.decodeSigningData(signingData: transaction) }
        let ffiSignature = try await remappingWalletKitError {
            try await device.raw.ethereumSignTx(path: account.derivationPath.raw, tx: tx)
        }
        let signature = EthereumSignature(v: ffiSignature.v, r: ffiSignature.r, s: ffiSignature.s)
        return try signedTransaction(transaction, signature: signature)
    }

    /// Signs `message` on the connected Trezor — the full interactive
    /// `EthereumSignTypedData` struct/value walk on Model T/Safe (or
    /// `EthereumSignTypedHash` on Trezor One) for typed data, or
    /// `EthereumSignMessage` for a personal message — showing it on the
    /// device's trusted screen for the user to confirm.
    ///
    /// - Throws: ``WalletKitError/unsupportedFeature`` if `message` isn't
    ///   an Ethereum message kind, ``WalletKitError/deviceDisconnected``
    ///   if the device has gone away, or
    ///   ``WalletKitError/userCancelled``/``WalletKitError/userRejectedOnDevice``
    ///   if the user backs out of a confirmation prompt.
    public func sign(message: SignableMessage) async throws -> Data {
        guard device.isConnected else {
            throw WalletKitError.deviceDisconnected
        }

        switch message {
        case .ethereumPersonal(let data):
            return try await remappingWalletKitError {
                try await device.raw.ethereumSignMessage(path: account.derivationPath.raw, message: data)
            }
        case .ethereumTypedData(let json):
            let fields = try remappingWalletKitError { try ethereumTypedDataFields(json: json) }
            return try await remappingWalletKitError {
                try await device.raw.ethereumSignTypedData(path: account.derivationPath.raw, fields: fields)
            }
        case .suiPersonal:
            throw WalletKitError.unsupportedFeature
        }
    }
}
