//
//  EthereumAddress.swift
//  WalletKit
//
//  Created by Andrey Yurkevich on 17/08/2026.
//  Copyright © 2026 Reefr Wallet. All rights reserved.
//

import Foundation
import class WalletKitRust.EthereumAddressFfi
import class WalletKitRust.EthereumSignerFfi

/// A validated Ethereum address containing 20 raw bytes.
public struct EthereumAddress: BlockchainAddress {
    let raw: EthereumAddressFfi

    init(raw: EthereumAddressFfi) {
        self.raw = raw
    }

    /// The EIP-55 mixed-case checksummed, `0x`-prefixed hex encoding of
    /// this address.
    public var string: String { raw.string() }

    /// The raw 20-byte address.
    public var rawBytes: Data { raw.rawBytes() }

    /// Ethereum-specific alias for ``string``, for call sites that already
    /// know they're holding an ``EthereumAddress`` rather than an
    /// `any BlockchainAddress`.
    public var checksummed: String { string }

    /// Parses and validates `string` as an Ethereum address — `0x`-prefixed,
    /// 40 hex characters, either all one case (no checksum to validate) or
    /// held to its EIP-55 mixed-case checksum.
    ///
    /// - Parameter string: The address string to parse.
    /// - Throws: ``WalletKitError/invalidAddress(reason:)`` for anything
    ///   else, including a mixed-case string with the wrong checksum.
    public init(string: String) throws {
        raw = try remappingWalletKitError { try EthereumAddressFfi.fromString(string: string) }
    }

    /// Wraps `rawBytes` as an Ethereum address.
    ///
    /// - Parameter rawBytes: The raw address bytes.
    /// - Throws: ``WalletKitError/invalidAddress(reason:)`` if
    ///   `rawBytes.count != 20`.
    public init(rawBytes: Data) throws {
        raw = try remappingWalletKitError { try EthereumAddressFfi(rawBytes: rawBytes) }
    }

    /// Derives the Ethereum address for `publicKey` — the last 20 bytes of
    /// the Keccak-256 hash of its uncompressed public-key encoding. The
    /// chain ID plays no part in address derivation, so this doesn't need
    /// an `EthereumPKeySigner`/`EthereumTrezorSigner` to compute.
    ///
    /// - Parameter publicKey: The public key to derive the address for.
    /// - Throws: ``WalletKitError/unsupportedCurve(curve:)`` if
    ///   `publicKey.curve` isn't secp256k1 — there is no Ethereum address
    ///   for an ed25519 key.
    public init(publicKey: PublicKey) throws {
        raw = try remappingWalletKitError { try EthereumSignerFfi(chainId: 1).address(publicKey: publicKey.raw) }
    }

    public static func == (lhs: EthereumAddress, rhs: EthereumAddress) -> Bool {
        lhs.rawBytes == rhs.rawBytes
    }

    // swiftlint:disable:next force_try
    public static let zero = try! EthereumAddress(rawBytes: Data(repeating: 0, count: 20))
}
