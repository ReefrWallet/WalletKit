//
//  AptosPKeySigner.swift
//  WalletKit
//
//  Copyright © 2026 Reefr Wallet. All rights reserved.
//

import Foundation
import WalletKitRust

/// A software-key ``Signer`` for Aptos: legacy Ed25519 or `SingleKey`
/// secp256k1 accounts.
public final class AptosPKeySigner: MessageSigner {
    public typealias Address = AptosAddress

    public let account: Account
    public let curve: Curve

    private let privateKey: PrivateKey
    private let raw: AptosSignerFfi

    /// - Throws: ``WalletKitError/unsupportedCurve(curve:)`` if
    ///   `privateKey.curve != curve`.
    public init(
        curve: Curve = .ed25519,
        network: AptosNetwork = .mainnet,
        privateKey: PrivateKey,
        derivationPath: DerivationPath
    ) throws {
        guard privateKey.curve == curve else {
            throw WalletKitError.unsupportedCurve(curve: privateKey.curve)
        }

        self.curve = curve
        self.privateKey = privateKey
        raw = AptosSignerFfi(curve: curve.raw)
        account = Account(
            blockchain: .aptos(network),
            derivationPath: derivationPath,
            curve: curve,
            source: .software,
            publicKey: privateKey.publicKey
        )
    }

    public func address() throws -> AptosAddress {
        try AptosAddress(publicKey: account.publicKey, curve: curve)
    }

    /// The account's public key as Aptos BCS-encodes it: `Ed25519PublicKey`
    /// (length-prefixed 32 bytes) or `AnyPublicKey::Secp256k1` (uncompressed).
    public func publicKeyBcs() throws -> Data {
        // Read from the simulation authenticator, whose layout the FFI pins:
        // Ed25519 `00 ‖ pk ‖ sig`, secp256k1 `04 02 ‖ AnyPublicKey ‖ AnySignature`.
        let authenticator = try remappingWalletKitError {
            try raw.simulationAuthenticator(publicKey: account.publicKey.raw)
        }

        return switch curve {
        case .ed25519: Data(authenticator.dropFirst(1).prefix(33))
        case .secp256k1: Data(authenticator.dropFirst(2).prefix(67))
        }
    }

    /// The raw public key inside ``publicKeyBcs()``: 32 Ed25519 bytes, or the
    /// 65-byte uncompressed secp256k1 point.
    public func publicKeyBytes() throws -> Data {
        let bcs = try publicKeyBcs()
        return Data(bcs.dropFirst(curve == .ed25519 ? 1 : 2))
    }

    /// `signature` (64 raw bytes) as Aptos BCS-encodes it: `Ed25519Signature`
    /// or `AnySignature::Secp256k1`.
    public func signatureBcs(_ signature: Data) -> Data {
        switch curve {
        case .ed25519: Data([0x40]) + signature
        case .secp256k1: Data([0x01, 0x40]) + signature
        }
    }

    /// Signs BCS `RawTransaction` bytes, returning the BCS
    /// `TransactionAuthenticator` that ``AptosClient`` appends on broadcast.
    public func sign(transaction: Data) async throws -> Data {
        try remappingWalletKitError { try raw.sign(rawTransaction: transaction, privateKey: privateKey.raw) }
    }

    /// Signs BCS `RawTransaction` bytes, returning the BCS
    /// `AccountAuthenticator` Wallet Standard `aptos:signTransaction` expects.
    public func signAccountAuthenticator(transaction: Data) async throws -> Data {
        try remappingWalletKitError {
            try raw.signAccountAuthenticator(rawTransaction: transaction, privateKey: privateKey.raw)
        }
    }

    /// Signs `.aptosMessage` bytes as-is, returning the raw 64-byte signature.
    ///
    /// - Throws: ``WalletKitError/unsupportedFeature`` for other message kinds.
    public func sign(message: SignableMessage) async throws -> Data {
        guard case let .aptosMessage(data) = message else {
            throw WalletKitError.unsupportedFeature
        }

        return try remappingWalletKitError { try raw.signMessage(message: data, privateKey: privateKey.raw) }
    }
}
