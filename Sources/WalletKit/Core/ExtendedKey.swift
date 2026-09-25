//
//  ExtendedKey.swift
//  WalletKit
//
//  Created by Andrey Yurkevich on 16/08/2026.
//

import WalletKitRust

/// A node in an HD (hierarchical-deterministic) key tree, covering BIP32
/// (secp256k1) and SLIP-0010 (ed25519) derivation.
///
/// An extended key may be private (able to derive child private keys and
/// sign) or public-only/"watch-only" (able to derive child public keys but
/// never recover a private key) — see ``canDerivePrivate``.
public protocol ExtendedKeyProtocol: AnyObject {
    /// The elliptic curve this key belongs to.
    var curve: Curve { get }

    /// The derivation scheme (BIP32 or SLIP-0010) this key's curve uses.
    var scheme: DerivationScheme { get }

    /// How many derivation steps this key is from the tree's master
    /// (depth-0) key.
    var depth: UInt8 { get }

    /// This key's index among its parent's children.
    var childIndex: UInt32 { get }

    /// Whether this key was derived at a hardened index.
    var isHardened: Bool { get }

    /// Whether this key can derive a private key (``privateKey()``) —
    /// `false` for a key imported from a public-only serialization (an
    /// xpub, or SLIP-0010's public equivalent).
    var canDerivePrivate: Bool { get }

    /// Derives the descendant key reached by walking `path` from this key.
    ///
    /// - Parameter path: The derivation path to walk, relative to this key.
    /// - Returns: The extended key at the end of `path`.
    func derive(_ path: DerivationPath) throws -> ExtendedKey

    /// Derives a single direct child of this key.
    ///
    /// - Parameters:
    ///   - index: The child's index (below the hardened offset — this is
    ///     added internally when `hardened` is `true`).
    ///   - hardened: Whether to derive at the hardened offset. ed25519
    ///     (SLIP-0010) keys only support hardened derivation.
    /// - Returns: The derived child extended key.
    func deriveChild(index: UInt32, hardened: Bool) throws -> ExtendedKey

    /// This key's public key.
    var publicKey: PublicKey { get }

    /// This key's private key.
    ///
    /// - Throws: ``WalletKitError/keyNotFound`` if this is a public-only
    ///   key (``canDerivePrivate`` is `false`).
    func privateKey() throws -> PrivateKey

    /// The Base58Check-encoded public serialization of this key (an
    /// "xpub"-style string).
    func serializedPublic() -> String

    /// The Base58Check-encoded private serialization of this key (an
    /// "xprv"-style string).
    ///
    /// - Warning: This encodes the raw private key and chain code —
    ///   treat it with the same care as the private key itself.
    /// - Throws: ``WalletKitError/keyNotFound`` if this is a public-only
    ///   key (``canDerivePrivate`` is `false`).
    func serializedPrivate() throws -> String
}

/// A node in an HD (hierarchical-deterministic) key tree.
///
/// Obtained from ``Seed/masterKey(curve:)`` (the tree root), from
/// ``derive(_:)``/``deriveChild(index:hardened:)`` (a descendant), or from
/// ``fromSerialized(_:curve:)`` (an imported xprv/xpub-style string).
public final class ExtendedKey: ExtendedKeyProtocol {
    let raw: ExtendedKeyFfi

    init(raw: ExtendedKeyFfi) {
        self.raw = raw
    }

    /// Imports a serialized extended key string (an xprv/xpub-style,
    /// Base58Check-encoded string).
    ///
    /// - Parameters:
    ///   - string: The serialized extended key string to import.
    ///   - curve: The elliptic curve `string` was serialized for. The
    ///     serialization format doesn't self-describe its curve for
    ///     ed25519/SLIP-0010 keys, so the caller must supply it —
    ///     passing the wrong curve silently produces a different, still
    ///     valid-looking key rather than an error.
    /// - Returns: The imported extended key.
    /// - Throws: ``WalletKitError/invalidDerivationPath(path:)`` if
    ///   `string` isn't a well-formed serialized extended key.
    public static func fromSerialized(_ string: String, curve: Curve) throws -> ExtendedKey {
        try remappingWalletKitError {
            ExtendedKey(raw: try ExtendedKeyFfi.fromSerialized(string: string, curve: curve.raw))
        }
    }

    /// The elliptic curve this key belongs to.
    public var curve: Curve { Curve(raw.curve()) }

    /// The derivation scheme (BIP32 or SLIP-0010) this key's curve uses.
    public var scheme: DerivationScheme { raw.scheme() }

    /// How many derivation steps this key is from the tree's master
    /// (depth-0) key.
    public var depth: UInt8 { raw.depth() }

    /// This key's index among its parent's children.
    public var childIndex: UInt32 { raw.childIndex() }

    /// Whether this key was derived at a hardened index.
    public var isHardened: Bool { raw.isHardened() }

    /// Whether this key can derive a private key (``privateKey()``) —
    /// `false` for a key imported from a public-only serialization (an
    /// xpub, or SLIP-0010's public equivalent).
    public var canDerivePrivate: Bool { raw.canDerivePrivate() }

    /// Derives the descendant key reached by walking `path` from this key.
    ///
    /// - Parameter path: The derivation path to walk, relative to this key.
    /// - Returns: The extended key at the end of `path`.
    public func derive(_ path: DerivationPath) throws -> ExtendedKey {
        try remappingWalletKitError { ExtendedKey(raw: try raw.derive(path: path.raw)) }
    }

    /// Derives a single direct child of this key.
    ///
    /// - Parameters:
    ///   - index: The child's index (below the hardened offset — this is
    ///     added internally when `hardened` is `true`).
    ///   - hardened: Whether to derive at the hardened offset. ed25519
    ///     (SLIP-0010) keys only support hardened derivation.
    /// - Returns: The derived child extended key.
    public func deriveChild(index: UInt32, hardened: Bool) throws -> ExtendedKey {
        try remappingWalletKitError { ExtendedKey(raw: try raw.deriveChild(index: index, hardened: hardened)) }
    }

    /// This key's public key.
    public var publicKey: PublicKey { PublicKey(raw: raw.publicKey()) }

    /// This key's private key.
    ///
    /// - Throws: ``WalletKitError/keyNotFound`` if this is a public-only
    ///   key (``canDerivePrivate`` is `false`).
    public func privateKey() throws -> PrivateKey {
        try remappingWalletKitError { PrivateKey(raw: try raw.privateKey()) }
    }

    /// The Base58Check-encoded public serialization of this key (an
    /// "xpub"-style string).
    public func serializedPublic() -> String {
        raw.serializedPublic()
    }

    /// The Base58Check-encoded private serialization of this key (an
    /// "xprv"-style string).
    ///
    /// - Warning: This encodes the raw private key and chain code —
    ///   treat it with the same care as the private key itself.
    /// - Throws: ``WalletKitError/keyNotFound`` if this is a public-only
    ///   key (``canDerivePrivate`` is `false`).
    public func serializedPrivate() throws -> String {
        try remappingWalletKitError { try raw.serializedPrivate() }
    }
}
