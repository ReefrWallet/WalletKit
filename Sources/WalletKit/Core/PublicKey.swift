//
//  PublicKey.swift
//  WalletKit
//
//  Created by Andrey Yurkevich on 16/08/2026.
//

import Foundation
import WalletKitRust

/// A curve-tagged public key that can verify signatures produced by its
/// corresponding private key.
public protocol PublicKeyProtocol: AnyObject {
    /// The elliptic curve this key belongs to.
    var curve: Curve { get }

    /// The raw key encoding: compressed SEC1 (33 bytes) for secp256k1,
    /// raw (32 bytes) for ed25519.
    var rawBytes: Data { get }

    /// Verifies that `signature` is a valid signature over `message` from
    /// the private key corresponding to this public key.
    ///
    /// - Parameters:
    ///   - signature: The signature to verify.
    ///   - message: The message the signature is claimed to cover.
    /// - Returns: `true` if `signature` is valid for `message` under this
    ///   key; `false` otherwise (including for malformed input — this never
    ///   throws).
    func verify(signature: Data, message: Data) -> Bool
}

/// A curve-tagged public key.
public final class PublicKey: PublicKeyProtocol {
    let raw: PublicKeyFfi

    init(raw: PublicKeyFfi) {
        self.raw = raw
    }

    /// The elliptic curve this key belongs to.
    public var curve: Curve { Curve(raw.curve()) }

    /// The raw key encoding: compressed SEC1 (33 bytes) for secp256k1,
    /// raw (32 bytes) for ed25519.
    public var rawBytes: Data { raw.rawBytes() }

    /// Verifies that `signature` is a valid signature over `message` from
    /// the private key corresponding to this public key.
    ///
    /// - Parameters:
    ///   - signature: The signature to verify.
    ///   - message: The message the signature is claimed to cover.
    /// - Returns: `true` if `signature` is valid for `message` under this
    ///   key; `false` otherwise (including for malformed input — this never
    ///   throws).
    public func verify(signature: Data, message: Data) -> Bool {
        raw.verify(signature: signature, message: message)
    }
}
