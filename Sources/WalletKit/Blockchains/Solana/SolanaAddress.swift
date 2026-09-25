//
//  SolanaAddress.swift
//  WalletKit
//
//  Created by Andrey Yurkevich on 21/09/2026.
//  Copyright © 2026 Reefr Wallet. All rights reserved.
//

import Foundation
import WalletKitRust

/// A validated Solana address (32 raw bytes) — plain (non-checksummed)
/// Base58 of either an ed25519 public key (a wallet) or a program-derived
/// address (a PDA, deliberately off the ed25519 curve).
public struct SolanaAddress: BlockchainAddress {
    let raw: SolanaAddressFfi

    init(raw: SolanaAddressFfi) {
        self.raw = raw
    }

    /// The plain (non-checksummed) Base58 encoding of this address.
    public var string: String { raw.string() }

    /// The raw 32-byte address.
    public var rawBytes: Data { raw.rawBytes() }

    /// Whether this address decompresses to a valid ed25519 curve point —
    /// `true` for a wallet address, `false` for a program-derived address.
    public var isOnCurve: Bool { raw.isOnCurve() }

    /// Parses `string` as a Solana address: plain Base58 decoding to
    /// exactly 32 bytes.
    ///
    /// - Parameter string: The address string to parse.
    /// - Throws: ``WalletKitError/invalidAddress(reason:)`` for non-Base58
    ///   characters or a decoded length other than 32.
    public init(string: String) throws {
        raw = try remappingWalletKitError { try SolanaAddressFfi.fromString(string: string) }
    }

    /// Wraps `rawBytes` as a Solana address.
    ///
    /// - Parameter rawBytes: The raw address bytes.
    /// - Throws: ``WalletKitError/invalidAddress(reason:)`` if
    ///   `rawBytes.count != 32`.
    public init(rawBytes: Data) throws {
        raw = try remappingWalletKitError { try SolanaAddressFfi(rawBytes: rawBytes) }
    }

    /// The Solana wallet address for `publicKey` — the raw 32-byte
    /// ed25519 public key, Base58-encoded with no hashing (unlike Sui,
    /// which hashes a scheme-flagged public key).
    ///
    /// - Parameter publicKey: The account's ed25519 public key.
    /// - Throws: ``WalletKitError/unsupportedCurve(curve:)`` if
    ///   `publicKey.curve != .ed25519`.
    public init(publicKey: PublicKey) throws {
        guard publicKey.curve == .ed25519 else {
            throw WalletKitError.unsupportedCurve(curve: publicKey.curve)
        }
        raw = try remappingWalletKitError { try SolanaAddressFfi(rawBytes: publicKey.rawBytes) }
    }

    public static func == (lhs: SolanaAddress, rhs: SolanaAddress) -> Bool {
        lhs.rawBytes == rhs.rawBytes
    }
}
