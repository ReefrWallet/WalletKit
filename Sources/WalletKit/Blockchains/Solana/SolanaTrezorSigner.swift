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
public final class SolanaTrezorSigner: Signer {
    public typealias Address = SolanaAddress

    public let account: WKAccount

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
        account = WKAccount(
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
            try await device.raw.solanaSignTx(path: account.derivationPath, transaction: transaction)
        }
    }
}
