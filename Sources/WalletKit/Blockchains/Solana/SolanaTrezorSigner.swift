//
//  SolanaTrezorSigner.swift
//  WalletKit
//
//  Created by Andrey Yurkevich on 21/09/2026.
//  Copyright © 2026 Reefr Wallet. All rights reserved.
//

import Foundation

/// A Solana signer backed by Trezor's native `SolanaSignTx` protocol.
///
/// The device receives the serialized message bytes plus the
/// ``SolanaUnsignedTransaction`` envelope's token-account metadata (so
/// its trusted screen can show an SPL transfer's mint/owner rather than
/// the opaque token-account address on the wire) and returns the raw
/// 64-byte ed25519 signature.
public final class SolanaTrezorSigner: Signer, MessageSigner {
    public typealias Address = SolanaAddress

    public let account: Account

    private let device: HardwareDevice

    /// Reads the ed25519 public key at `derivationPath` from `device` and
    /// derives its Solana address.
    public init(
        network: SolanaNetwork = .mainnet,
        device: HardwareDevice,
        derivationPath: DerivationPath
    ) async throws {
        let publicKey = try await device.publicKey(path: derivationPath, curve: .ed25519)
        self.device = device
        account = Account(
            blockchain: .solana(network),
            derivationPath: derivationPath,
            curve: .ed25519,
            source: device.source,
            publicKey: publicKey
        )
    }

    public func address() throws -> SolanaAddress {
        try SolanaAddress(publicKey: account.publicKey)
    }

    /// Signs `transaction`'s ``SolanaUnsignedTransaction`` envelope
    /// on-device.
    ///
    /// - Parameter transaction: The JSON envelope produced by
    ///   ``SolanaTransactionBuilder``.
    /// - Returns: The raw 64-byte ed25519 signature.
    public func sign(transaction: Data) async throws -> Data {
        guard device.isConnected else {
            throw WalletKitError.deviceDisconnected
        }

        guard let transaction = String(data: transaction, encoding: .utf8) else {
            throw WalletKitError.signingFailed(reason: "A Trezor Solana transaction must be valid UTF-8 JSON.")
        }

        return try await remappingWalletKitError {
            try await device.raw.solanaSignTx(path: account.derivationPath.raw, transaction: transaction)
        }
    }

    /// Signs a Solana off-chain message (`solana:signMessage`) on-device
    /// using Trezor's structured OCMS v1 request: the UTF-8 text plus this
    /// account's key as the sole signer.
    ///
    /// Unlike ``SolanaPKeySigner/sign(message:)``, the device doesn't sign
    /// the raw bytes — it signs its own serialization of the request, so
    /// verify against ``offchainMessageBytes(_:signer:)``, not the text.
    ///
    /// - Throws: ``WalletKitError/unsupportedFeature`` if `message` isn't
    ///   ``SignableMessage/solanaMessage(_:)`` or isn't non-empty UTF-8
    ///   text (the only thing the firmware accepts).
    public func sign(message: SignableMessage) async throws -> Data {
        guard case let .solanaMessage(data) = message,
              !data.isEmpty,
              let text = String(data: data, encoding: .utf8)
        else {
            throw WalletKitError.unsupportedFeature
        }

        guard device.isConnected else {
            throw WalletKitError.deviceDisconnected
        }

        let signer = try address().rawBytes

        return try await remappingWalletKitError {
            try await device.raw.solanaSignMessage(
                path: account.derivationPath.raw,
                message: text,
                signers: [signer]
            )
        }
    }

    /// The exact bytes the device signs for an OCMS v1 message with a single
    /// `signer`: `\xffsolana offchain` ‖ version `1` ‖ signer count ‖
    /// signer ‖ UTF-8 message.
    public static func offchainMessageBytes(_ message: String, signer: SolanaAddress) -> Data {
        var bytes = Data([0xFF])
        bytes.append(Data("solana offchain".utf8))
        bytes.append(contentsOf: [1, 1])
        bytes.append(signer.rawBytes)
        bytes.append(Data(message.utf8))
        return bytes
    }
}
