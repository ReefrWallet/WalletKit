//
//  WKAccount.swift
//  WalletKit
//
//  Created by Andrey Yurkevich on 16/08/2026.
//

import WalletKitRust

/// The elliptic curve a key/derivation scheme is based on.
public enum Curve: String, Codable, CaseIterable, Sendable {
    case secp256k1
    case ed25519

    init(_ raw: CurveFfi) {
        switch raw {
        case .secp256k1: self = .secp256k1
        case .ed25519: self = .ed25519
        }
    }

    var raw: CurveFfi {
        switch self {
        case .secp256k1: .secp256k1
        case .ed25519: .ed25519
        }
    }
}

extension Curve: CustomStringConvertible {
    public var description: String {
        switch self {
        case .secp256k1: "ECDSA Secp256k1"
        case .ed25519: "Ed25519 (EdDSA)"
        }
    }
}

/// Where an ``Account``'s signing key material actually lives.
public enum KeySource: Equatable {
    /// The key is derived and held in-app (e.g. from a ``Mnemonic``/``Seed``).
    case software

    /// The key lives on a connected hardware wallet, described by the
    /// associated device info.
    case hardware(HardwareDeviceInfo)
}

/// A single derived account: a blockchain, a derivation path, and the
/// public key derived at that path.
public protocol WKAccountProtocol: AnyObject {
    /// The blockchain this account is for.
    var blockchain: WKBlockchain { get }

    /// The derivation path this account's public key was derived at.
    var derivationPath: DerivationPath { get }

    /// The elliptic curve this account's keys use.
    var curve: Curve { get }

    /// Where this account's key material lives (software or hardware).
    var source: KeySource { get }

    /// This account's public key.
    var publicKey: PublicKey { get }
}

/// A single derived account, produced by a ``Signer`` conformer or a
/// ``HardwareDevice``.
public final class WKAccount: WKAccountProtocol {
    /// The blockchain this account is for.
    public let blockchain: WKBlockchain

    /// The derivation path this account's public key was derived at.
    public let derivationPath: DerivationPath

    /// The elliptic curve this account's keys use.
    public let curve: Curve

    /// Where this account's key material lives (software or hardware).
    public let source: KeySource

    /// This account's public key.
    public let publicKey: PublicKey

    init(
        blockchain: WKBlockchain,
        derivationPath: DerivationPath,
        curve: Curve,
        source: KeySource,
        publicKey: PublicKey
    ) {
        self.blockchain = blockchain
        self.derivationPath = derivationPath
        self.curve = curve
        self.source = source
        self.publicKey = publicKey
    }
}
