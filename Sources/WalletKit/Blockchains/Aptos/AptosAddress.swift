//
//  AptosAddress.swift
//  WalletKit
//
//  Copyright © 2026 Reefr Wallet. All rights reserved.
//

import Foundation
import WalletKitRust

/// A validated Aptos account address (32 raw bytes).
public struct AptosAddress: BlockchainAddress, Hashable {
    let raw: AptosAddressFfi

    init(raw: AptosAddressFfi) {
        self.raw = raw
    }

    /// AIP-40 display form: `0x1` for special addresses, otherwise `0x` plus
    /// 64 lowercase hex characters.
    public var string: String { raw.string() }

    /// `0x` plus 64 lowercase hex characters, for every address — the form
    /// the indexer stores.
    public var longString: String { raw.stringLong() }

    public var rawBytes: Data { raw.rawBytes() }

    /// Parses AIP-40 strict form: `0x` plus 64 hex characters, or `0x0`–`0xf`
    /// for special addresses.
    ///
    /// - Throws: ``WalletKitError/invalidAddress(reason:)``.
    public init(string: String) throws {
        raw = try remappingWalletKitError { try AptosAddressFfi.fromString(string: string) }
    }

    /// Parses a chain-reported address, left-padding stripped leading zeros.
    ///
    /// - Throws: ``WalletKitError/invalidAddress(reason:)``.
    public init(chainString: String) throws {
        raw = try remappingWalletKitError { try AptosAddressFfi.fromStringRelaxed(string: chainString) }
    }

    /// - Throws: ``WalletKitError/invalidAddress(reason:)`` unless 32 bytes.
    public init(rawBytes: Data) throws {
        raw = try remappingWalletKitError { try AptosAddressFfi(rawBytes: rawBytes) }
    }

    /// Derives the address for `publicKey`: legacy Ed25519 or `SingleKey`
    /// secp256k1, selected by `curve`.
    ///
    /// - Throws: ``WalletKitError/unsupportedCurve(curve:)`` if
    ///   `publicKey.curve != curve`.
    public init(publicKey: PublicKey, curve: Curve) throws {
        raw = try remappingWalletKitError { try AptosSignerFfi(curve: curve.raw).address(publicKey: publicKey.raw) }
    }

    public static func == (lhs: AptosAddress, rhs: AptosAddress) -> Bool {
        lhs.rawBytes == rhs.rawBytes
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(rawBytes)
    }
}
