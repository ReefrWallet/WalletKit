//
//  PrivateKey.swift
//  WalletKit
//
//  Created by Andrey Yurkevich on 16/08/2026.
//

import Foundation
import WalletKitRust

/// A curve-tagged private key capable of signing messages.
///
/// There is intentionally no way to read out the raw key bytes — only to
/// derive the corresponding public key or produce a signature.
public protocol PrivateKeyProtocol: AnyObject {
    /// The elliptic curve this key belongs to.
    var curve: Curve { get }

    /// The public key corresponding to this private key.
    var publicKey: PublicKey { get }

    /// Signs `message`.
    ///
    /// - Parameter message: The message to sign. For secp256k1 keys this is
    ///   SHA-256-hashed before signing; for ed25519 keys it's signed
    ///   directly (EdDSA hashes internally).
    /// - Returns: The signature bytes.
    /// - Throws: ``WalletKitError/signingFailed(reason:)`` if signing fails.
    func sign(message: Data) throws -> Data
}

/// A curve-tagged private key handle, backed by ``PrivateKeyFfi``.
///
/// The underlying raw bytes live in Rust-managed, zeroized memory and are
/// never exposed to Swift — this type can only be used to derive a public
/// key or produce signatures.
public final class PrivateKey: PrivateKeyProtocol {
    let raw: PrivateKeyFfi

    init(raw: PrivateKeyFfi) {
        self.raw = raw
    }

    /// Imports a private key directly from raw bytes — e.g. an externally
    /// held key, or (in tests) a shared test vector — bypassing
    /// mnemonic/BIP32 derivation entirely.
    ///
    /// - Parameters:
    ///   - curve: The elliptic curve `rawBytes` is a scalar/seed for.
    ///   - rawBytes: The raw 32-byte private key material.
    /// - Throws: ``WalletKitError/signingFailed(reason:)`` if
    ///   `rawBytes.count != 32`, or (secp256k1 only) if the 32 bytes aren't
    ///   a valid scalar in the curve's order.
    public init(curve: Curve, rawBytes: Data) throws {
        raw = try remappingWalletKitError { try PrivateKeyFfi.fromRawBytes(curve: curve.raw, rawBytes: rawBytes) }
    }

    /// The elliptic curve this key belongs to.
    public var curve: Curve { Curve(raw.curve()) }

    /// The public key corresponding to this private key.
    public var publicKey: PublicKey { PublicKey(raw: raw.publicKey()) }

    /// Signs `message`.
    ///
    /// - Parameter message: The message to sign. For secp256k1 keys this is
    ///   SHA-256-hashed before signing; for ed25519 keys it's signed
    ///   directly (EdDSA hashes internally).
    /// - Returns: The signature bytes.
    /// - Throws: ``WalletKitError/signingFailed(reason:)`` if signing fails.
    public func sign(message: Data) throws -> Data {
        try remappingWalletKitError { try raw.sign(message: message) }
    }
}
