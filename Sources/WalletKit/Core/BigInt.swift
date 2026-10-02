//
//  BigInt.swift
//  WalletKit
//
//  Created by Andrey Yurkevich on 17/08/2026.
//

import BigInt
import Foundation
import WalletKitRust

/// Bridges ``BigIntFfi`` — the sign-and-magnitude, big-endian-bytes
/// representation crossing the UniFFI boundary — with attaswift/BigInt's
/// `BigInt`/`BigUInt`, so cryptocurrency APIs (balances, gas prices,
/// Solidity `uint256`/`int256` values, ...) can be worked with as
/// arbitrary-precision integers on both sides of the FFI boundary.
///
/// `BigIntFfi.magnitudeBeBytes` is always the minimal big-endian encoding
/// of the absolute value (no leading zero bytes; zero is an empty
/// `Data`) — exactly `BigUInt.serialize()`'s convention — so these
/// conversions are a direct field mapping with no bit-twiddling.

extension BigUInt {
    /// Wraps `ffi`'s magnitude as a `BigUInt`.
    ///
    /// - Parameter ffi: The value to convert. Must not be negative.
    /// - Returns: `nil` if `ffi.negative` is `true` — a negative value has
    ///   no unsigned representation.
    init?(_ ffi: BigIntFfi) {
        guard !ffi.negative else {
            return nil
        }

        self.init(ffi.magnitudeBeBytes)
    }
}

extension BigInt {
    /// Wraps `ffi` as a `BigInt`, preserving its sign.
    ///
    /// - Parameter ffi: The value to convert.
    init(_ ffi: BigIntFfi) {
        self.init(sign: ffi.negative ? .minus : .plus, magnitude: BigUInt(ffi.magnitudeBeBytes))
    }
}

extension BigIntFfi {
    /// Wraps `value` as a `BigIntFfi`.
    ///
    /// - Parameter value: The value to convert.
    init(_ value: BigUInt) {
        self.init(magnitudeBeBytes: value.serialize(), negative: false)
    }

    /// Wraps `value` as a `BigIntFfi`, preserving its sign.
    ///
    /// - Parameter value: The value to convert.
    init(_ value: BigInt) {
        self.init(magnitudeBeBytes: value.magnitude.serialize(), negative: value.sign == .minus)
    }
}
