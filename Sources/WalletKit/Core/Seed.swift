//
//  Seed.swift
//  WalletKit
//
//  Created by Andrey Yurkevich on 16/08/2026.
//

import Foundation
import WalletKitRust

/// A 64-byte BIP39 seed, and the entry point for master-key derivation.
public protocol SeedProtocol: AnyObject {
    /// Reconstructs a seed from previously exported raw bytes (see
    /// ``exportRaw()``).
    ///
    /// - Parameter rawBytes: The raw 64-byte seed.
    /// - Throws: ``WalletKitError/invalidSeed(reason:)`` if
    ///   `rawBytes.count != 64`.
    init(rawBytes: Data) throws

    /// Derives the master ``ExtendedKey`` for `curve` from this seed, via
    /// HMAC-SHA512 with the curve's standard key ("Bitcoin seed" for
    /// secp256k1, "ed25519 seed" for ed25519).
    ///
    /// - Parameter curve: The elliptic curve to derive the master key for.
    /// - Returns: The depth-0 master ``ExtendedKey`` for `curve`.
    func masterKey(curve: Curve) throws -> ExtendedKey

    /// The raw 64-byte seed.
    ///
    /// - Warning: This is as sensitive as the wallet's private keys —
    ///   anyone with the seed can recreate every account derived from it.
    ///   Treat it as short-lived and never log it.
    func exportRaw() -> Data
}

/// A 64-byte BIP39 seed.
///
/// Derive a seed from ``Mnemonic/toSeed(passphrase:)``. Export raw bytes only
/// for an explicit backup or recovery operation.
public final class Seed: SeedProtocol {
    let raw: SeedFfi

    init(raw: SeedFfi) {
        self.raw = raw
    }

    /// Reconstructs a seed from previously exported raw bytes (see
    /// ``exportRaw()``).
    ///
    /// - Parameter rawBytes: The raw 64-byte seed.
    /// - Throws: ``WalletKitError/invalidSeed(reason:)`` if
    ///   `rawBytes.count != 64`.
    public convenience init(rawBytes: Data) throws {
        self.init(raw: try remappingWalletKitError { try SeedFfi.fromRawBytes(rawBytes: rawBytes) })
    }

    /// Derives the master ``ExtendedKey`` for `curve` from this seed, via
    /// HMAC-SHA512 with the curve's standard key ("Bitcoin seed" for
    /// secp256k1, "ed25519 seed" for ed25519).
    ///
    /// - Parameter curve: The elliptic curve to derive the master key for.
    /// - Returns: The depth-0 master ``ExtendedKey`` for `curve`.
    public func masterKey(curve: Curve) throws -> ExtendedKey {
        ExtendedKey(raw: raw.masterKey(curve: curve.raw))
    }

    /// The raw 64-byte seed.
    ///
    /// - Warning: This is as sensitive as the wallet's private keys —
    ///   anyone with the seed can recreate every account derived from it.
    ///   Treat it as short-lived and never log it.
    public func exportRaw() -> Data {
        raw.exportRaw()
    }
}
