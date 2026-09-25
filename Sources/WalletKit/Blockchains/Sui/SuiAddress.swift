//
//  SuiAddress.swift
//  WalletKit
//
//  Created by Andrey Yurkevich on 17/08/2026.
//  Copyright © 2026 Reefr Wallet. All rights reserved.
//

import Foundation
import WalletKitRust

/// A validated Sui address (32 raw bytes) — the Blake2b-256 digest of a
/// one-byte scheme flag followed by the account's public key bytes.
public struct SuiAddress: BlockchainAddress {
    let raw: SuiAddressFfi

    init(raw: SuiAddressFfi) {
        self.raw = raw
    }

    /// The `0x`-prefixed, all-lowercase hex encoding of this address.
    public var string: String { raw.string() }

    /// The raw 32-byte address.
    public var rawBytes: Data { raw.rawBytes() }

    /// Parses `string` as a Sui address: `0x`-prefixed, 64 hex characters.
    /// Unlike Ethereum, Sui defines no checksum, so casing is never
    /// validated.
    ///
    /// - Parameter string: The address string to parse.
    /// - Throws: ``WalletKitError/invalidAddress(reason:)`` for a missing
    ///   `0x` prefix, wrong length, or non-hex characters.
    public init(string: String) throws {
        raw = try remappingWalletKitError { try SuiAddressFfi.fromString(string: string) }
    }

    /// Wraps `rawBytes` as a Sui address.
    ///
    /// - Parameter rawBytes: The raw address bytes.
    /// - Throws: ``WalletKitError/invalidAddress(reason:)`` if
    ///   `rawBytes.count != 32`.
    public init(rawBytes: Data) throws {
        raw = try remappingWalletKitError { try SuiAddressFfi(rawBytes: rawBytes) }
    }

    /// Derives the Sui address for `publicKey`: the Blake2b-256 hash of a
    /// one-byte scheme flag (selected by `curve`) followed by `publicKey`'s
    /// raw bytes, with no truncation.
    ///
    /// - Parameters:
    ///   - publicKey: The public key to derive the address for.
    ///   - curve: Which signature scheme's flag byte to use. Must match
    ///     `publicKey.curve` — unlike Ethereum, Sui supports more than one
    ///     curve, and the scheme travels with the address itself.
    /// - Throws: ``WalletKitError/unsupportedCurve(curve:)`` if
    ///   `publicKey.curve != curve`.
    public init(publicKey: PublicKey, curve: Curve) throws {
        raw = try remappingWalletKitError { try SuiSignerFfi(curve: curve.raw).address(publicKey: publicKey.raw) }
    }

    public static func == (lhs: SuiAddress, rhs: SuiAddress) -> Bool {
        lhs.rawBytes == rhs.rawBytes
    }
}
