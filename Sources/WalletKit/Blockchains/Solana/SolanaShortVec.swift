//
//  SolanaShortVec.swift
//  WalletKit
//
//  Created by Andrey Yurkevich on 21/09/2026.
//  Copyright © 2026 Reefr Wallet. All rights reserved.
//

import Foundation

/// Solana's "compact-u16" (short-vec) length prefix — ULEB128 restricted
/// to values that fit in 16 bits, so it never takes more than 3 bytes (7
/// + 7 + 2 bits). Prefixes every variable-length list in a legacy
/// `Message` — account keys, instructions, and each instruction's
/// account-index/data byte vectors — and, outside the message itself,
/// the transaction wire format's signature count.
enum SolanaShortVec {
    /// Encodes `value` as a compact-u16.
    ///
    /// - Parameter value: The length to encode. Must fit in 16 bits.
    static func encode(_ value: Int) -> Data {
        precondition((0...0xFFFF).contains(value), "compact-u16 only encodes 0...65535, got \(value)")

        var remaining = UInt16(value)
        var out = Data()
        while true {
            var byte = UInt8(remaining & 0x7F)
            remaining >>= 7
            if remaining == 0 {
                out.append(byte)
                break
            } else {
                byte |= 0x80
                out.append(byte)
            }
        }
        return out
    }

    /// Decodes a compact-u16 length prefix from `data` starting at
    /// `offset`, advancing `offset` past the bytes it consumed.
    ///
    /// - Throws: ``WalletKitError/internalError(message:)`` if `data` runs
    ///   out of bytes before a terminating (high-bit-clear) byte.
    static func decode(_ data: Data, offset: inout Int) throws -> Int {
        var result = 0
        var shift = 0
        while true {
            guard offset < data.count else {
                throw WalletKitError.internalError(message: "compact-u16 ran out of bytes")
            }
            let byte = data[offset]
            offset += 1
            result |= Int(byte & 0x7F) << shift
            if byte & 0x80 == 0 {
                break
            }
            shift += 7
        }
        return result
    }

    /// Decodes a compact-u16 length prefix the same way ``decode(_:offset:)``
    /// does, but additionally enforces the wire-format guarantees a
    /// fail-closed parser needs: no more than 3 bytes (compact-u16 never
    /// needs a 4th), the decoded value fits in 16 bits, and the encoding is
    /// canonical — i.e. exactly what ``encode(_:)`` would have produced for
    /// that value, rejecting a padded/non-minimal encoding (e.g. `0x80 0x00`
    /// for `0`) that could let two byte-different-but-equal-value encodings
    /// of the same transaction coexist.
    ///
    /// - Throws: ``WalletKitError/internalError(message:)`` if `data` runs
    ///   out of bytes, the value takes more than 3 bytes, the decoded value
    ///   exceeds `0xFFFF`, or the encoding isn't canonical.
    static func decodeCanonical(_ data: Data, offset: inout Int) throws -> Int {
        let start = offset
        var result = 0
        var shift = 0
        var byteCount = 0

        while true {
            guard offset < data.count else {
                throw WalletKitError.internalError(message: "compact-u16 ran out of bytes")
            }

            guard byteCount < 3 else {
                throw WalletKitError.internalError(message: "compact-u16 took more than 3 bytes")
            }

            let byte = data[offset]

            offset += 1
            byteCount += 1
            result |= Int(byte & 0x7F) << shift

            if byte & 0x80 == 0 {
                break
            }

            shift += 7
        }

        guard result <= 0xFFFF else {
            throw WalletKitError.internalError(message: "compact-u16 value exceeds 0xFFFF")
        }

        let consumed = Data(data[start..<offset])
        guard consumed == encode(result) else {
            throw WalletKitError.internalError(message: "compact-u16 encoding is not canonical")
        }

        return result
    }
}
