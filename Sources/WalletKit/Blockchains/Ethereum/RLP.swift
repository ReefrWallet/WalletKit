//
//  RLP.swift
//  WalletKit
//
//  Created by Andrey Yurkevich on 28/08/2026.
//  Copyright © 2026 Reefr Wallet. All rights reserved.
//

import Foundation

/// A minimal Ethereum RLP encoder — byte-strings and lists only, which is
/// everything an EIP-155 legacy transaction's flat 9-field structure needs.
/// Used by ``UnsignedLegacyTransaction`` to produce the
/// ``UnsignedLegacyTransaction/signingData`` bytes
/// ``EthereumPKeySigner/sign(transaction:)`` accepts as input.
public enum RLP {
    /// Encodes a single byte-string item.
    ///
    /// A single byte in the range `[0x00, 0x7F]` is its own encoding
    /// (no length prefix); everything else gets an RLP length header.
    public static func encode(_ bytes: Data) -> Data {
        if bytes.count == 1, let byte = bytes.first, byte < 0x80 {
            return bytes
        }

        return encodeHeader(base: 0x80, longBase: 0xB7, count: bytes.count) + bytes
    }

    /// Encodes a list whose `items` are already individually RLP-encoded.
    ///
    /// The list is `0xC0..0xF7` for short payloads and `0xF8+len(length)`
    /// for long ones — the same two-tier header that byte-strings use, but
    /// with a different base byte.
    public static func encodeList(_ items: [Data]) -> Data {
        let payload = items.reduce(Data(), +)
        return encodeHeader(base: 0xC0, longBase: 0xF7, count: payload.count) + payload
    }

    private static func encodeHeader(base: UInt8, longBase: UInt8, count: Int) -> Data {
        if count <= 55 {
            return Data([base + UInt8(count)])
        }

        var lengthBytes = Data()
        var remaining = count
        while remaining > 0 {
            lengthBytes.insert(UInt8(remaining & 0xFF), at: 0)
            remaining >>= 8
        }

        return Data([longBase + UInt8(lengthBytes.count)]) + lengthBytes
    }
}
