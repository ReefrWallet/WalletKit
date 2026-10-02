//
//  BCS.swift
//  WalletKit
//
//  Created by Andrey Yurkevich on 28/08/2026.
//  Copyright © 2026 Reefr Wallet. All rights reserved.
//

import Foundation

/// A minimal BCS (Binary Canonical Serialization) encoder — just the
/// primitives a Sui `TransactionDataV1` needs: ULEB128 lengths,
/// little-endian fixed-width integers, and length-prefixed byte vectors.
///
/// Used by the `UnsignedSui*` transaction builders to produce the raw BCS
/// bytes that ``SuiPKeySigner/sign(transaction:)`` accepts as input.
public enum BCS {
    /// Encodes `value` as ULEB128 — how BCS encodes `Vec<T>` lengths and
    /// enum variant tags.
    ///
    /// Values in `[0, 127]` encode as a single byte; larger values use
    /// multiple bytes with the high bit of each byte (except the last) set.
    public static func uleb128(_ value: Int) -> Data {
        var remaining = UInt(value)
        var out = Data()
        repeat {
            var byte = UInt8(remaining & 0x7F)
            remaining >>= 7
            if remaining != 0 {
                byte |= 0x80
            }

            out.append(byte)
        } while remaining != 0
        return out
    }

    /// Encodes `value` as 8 little-endian bytes — how BCS encodes `u64`,
    /// including a `Coin` balance or a gas price/budget.
    public static func u64(_ value: UInt64) -> Data {
        withUnsafeBytes(of: value.littleEndian) { Data($0) }
    }

    /// Encodes `value` as 2 little-endian bytes — how BCS encodes a
    /// `u16`, including an `Argument::Input`, `Argument::Result`, or
    /// `Argument::NestedResult` index inside a PTB command.
    public static func u16(_ value: UInt16) -> Data {
        withUnsafeBytes(of: value.littleEndian) { Data($0) }
    }

    /// Encodes `bytes` as a length-prefixed byte vector: a ULEB128 length
    /// followed by the raw bytes — how BCS encodes `Vec<u8>`, e.g. a
    /// `CallArg::Pure` payload or an `ObjectDigest`.
    public static func byteVector(_ bytes: Data) -> Data {
        uleb128(bytes.count) + bytes
    }
}
