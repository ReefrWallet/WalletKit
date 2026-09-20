// Tests for Sources/Core/BigInt.swift: the BigInt/BigUInt <-> BigIntFfi
// bridge. `bigIntEcho`/`bigIntFromU64`/`bigIntToU64` (exported straight
// from `common::big_int` in the Rust crate) exercise the actual FFI
// boundary, confirming values survive the Rust <-> Swift round trip
// intact rather than just checking the Swift-side conversion in
// isolation.

import BigInt
import Foundation
import Testing
@testable import WalletKit
import WalletKitRust

// A realistic crypto value: `2^256 - 1`, the maximum Solidity `uint256`.
private let maxUInt256 = BigUInt(1) << 256 - BigUInt(1)

struct BigIntTests {
    // MARK: - BigUInt <-> BigIntFfi (Swift-only)

    @Test func bigUIntRoundTripsThroughBigIntFfi() {
        for value in [BigUInt(0), BigUInt(1), BigUInt(42), BigUInt(UInt64.max), maxUInt256] {
            #expect(BigUInt(BigIntFfi(value)) == value)
        }
    }

    @Test func bigIntFfiFromZeroBigUIntHasAnEmptyMagnitudeAndIsNotNegative() {
        let ffi = BigIntFfi(BigUInt(0))
        #expect(ffi.magnitudeBeBytes.isEmpty)
        #expect(ffi.negative == false)
    }

    // MARK: - BigInt <-> BigIntFfi (Swift-only)

    @Test func bigIntRoundTripsThroughBigIntFfiIncludingSign() {
        let values = [BigInt(0), BigInt(1), BigInt(-1), BigInt(-42), BigInt(maxUInt256), -BigInt(maxUInt256)]
        for value in values {
            #expect(BigInt(BigIntFfi(value)) == value)
        }
    }

    @Test func negativeBigIntFfiProducesANilBigUInt() {
        let negative = BigIntFfi(BigInt(-5))
        #expect(BigUInt(negative) == nil)
    }

    // MARK: - Across the actual FFI boundary (Rust <-> Swift <-> Rust)

    @Test func bigIntEchoRoundTripsArbitraryWidthValuesThroughRust() {
        let huge = maxUInt256 + BigUInt(1) // one past uint256's range
        let echoedUnsigned = bigIntEcho(value: BigIntFfi(huge))
        #expect(BigUInt(echoedUnsigned) == huge)

        let negativeHuge = -BigInt(huge)
        let echoedSigned = bigIntEcho(value: BigIntFfi(negativeHuge))
        #expect(BigInt(echoedSigned) == negativeHuge)
    }

    @Test func bigIntFromU64AndToU64RoundTripThroughRust() throws {
        for value: UInt64 in [0, 1, 42, .max] {
            let ffi = bigIntFromU64(value: value)
            #expect(BigUInt(ffi) == BigUInt(value))
            #expect(try bigIntToU64(value: ffi) == value)
        }
    }

    @Test func bigIntToU64ThrowsForANegativeValue() {
        let negativeOne = BigIntFfi(BigInt(-1))
        #expect(throws: WalletKitErrorFfi.self) {
            try bigIntToU64(value: negativeOne)
        }
    }

    @Test func bigIntToU64ThrowsForAValueThatDoesNotFit() {
        let tooLarge = BigIntFfi(BigUInt(1) << 64) // 2^64 — one bit past u64's range
        #expect(throws: WalletKitErrorFfi.self) {
            try bigIntToU64(value: tooLarge)
        }
    }
}
