//
//  EthereumABI.swift
//  WalletKit
//
//  Created by Andrey Yurkevich on 17/08/2026.
//  Copyright © 2026 Reefr Wallet. All rights reserved.
//

import BigInt
import Foundation
import WalletKitRust

/// A parameter value for an ABI-encoded contract call. Covers the static
/// (fixed-width) Solidity types this client needs — `address`, `uintN`,
/// `bool` — each encoding to exactly one 32-byte ABI word.
///
/// - Note: Dynamic types (`string`, `bytes`, arrays, tuples) aren't
///   covered — ERC-20 `balanceOf` and Chainlink `latestRoundData()`, the
///   calls this client makes, only need static words.
public enum EthereumABIValue {
    case address(EthereumAddress)
    case bool(Bool)
    case bytes32(Data)
    case uint256(BigUInt)

    var word: Data {
        switch self {
        case .address(let address):
            return Data(repeating: 0, count: 12) + address.rawBytes
        case .bool(let value):
            return Data(repeating: 0, count: 31) + Data([value ? 1 : 0])
        case .bytes32(let value):
            // Precondition: value is exactly 32 bytes — the caller's
            // responsibility, e.g. an already-32-byte ENS namehash.
            return value
        case .uint256(let value):
            // Precondition: value fits in 256 bits (32 bytes) — the
            // caller's responsibility, same as any other uint256 field.
            let bytes = value.serialize()
            return Data(repeating: 0, count: 32 - bytes.count) + bytes
        }
    }
}

/// Minimal Ethereum ABI encode/decode helpers — function-selector computation,
/// static-word call-data encoding, and static-word return-data decoding.
/// Backs `EthereumRPCClient`'s contract-call methods (`erc20Balance`,
/// `latestRoundData`) and is available directly for a caller's own contract
/// calls via `EthereumRPCClient.call(to:data:)`.
public enum EthereumABI {
    private static func word(_ value: BigUInt) -> Data {
        let bytes = value.serialize()
        return Data(repeating: 0, count: 32 - bytes.count) + bytes
    }

    /// Encodes Multicall3's `aggregate3((address,bool,bytes)[])` input for
    /// read-only calls.
    static func encodeAggregate3( // swiftlint:disable:next large_tuple
        _ calls: [(target: EthereumAddress, allowFailure: Bool, callData: Data)]
    ) -> Data {
        let encodedCalls = calls.map { call -> Data in
            let paddedLength = ((call.callData.count + 31) / 32) * 32
            return EthereumABIValue.address(call.target).word
                + EthereumABIValue.bool(call.allowFailure).word
                + word(96)
                + word(BigUInt(call.callData.count))
                + call.callData
                + Data(repeating: 0, count: paddedLength - call.callData.count)
        }
        let offsets = calls.indices.reduce(into: Data()) { result, index in
            // Dynamic-array element offsets are relative to the array's length
            // word, so the first element follows the length plus all offsets.
            let offset = 32 + calls.count * 32 + encodedCalls[..<index].reduce(0) { $0 + $1.count }
            result += word(BigUInt(offset))
        }
        return encodeCall(selector: selector("aggregate3((address,bool,bytes)[])"))
            + word(32)
            + word(BigUInt(calls.count))
            + offsets
            + encodedCalls.reduce(Data(), +)
    }

    /// Decodes Multicall3's `(bool success, bytes returnData)[]` result.
    static func decodeAggregate3(_ data: Data) throws -> [(success: Bool, returnData: Data)] {
        guard let arrayOffset = Int(exactly: decodeUInt256(data.prefix(32))),
              arrayOffset + 32 <= data.count
        else {
            throw BlockchainClientError.decodingFailed(reason: "aggregate3 response has an invalid array offset")
        }
        let arrayStart = data.startIndex + arrayOffset
        let count = Int(exactly: decodeUInt256(data[arrayStart..<arrayStart + 32])) ?? -1
        guard count >= 0 else {
            throw BlockchainClientError.decodingFailed(reason: "aggregate3 response has an invalid result count")
        }
        let headsStart = arrayStart + 32
        guard headsStart + count * 32 <= data.endIndex else {
            throw BlockchainClientError.decodingFailed(reason: "aggregate3 response has truncated result heads")
        }

        return try (0..<count).map { index in
            let relativeOffset = Int(
                exactly: decodeUInt256(data[headsStart + index * 32..<headsStart + (index + 1) * 32])
            ) ?? -1
            let tupleStart = arrayStart + relativeOffset
            guard relativeOffset >= 0, tupleStart + 64 <= data.endIndex else {
                throw BlockchainClientError.decodingFailed(reason: "aggregate3 response has an invalid tuple offset")
            }
            let success = decodeBool(data[tupleStart..<tupleStart + 32])
            let bytesOffset = Int(exactly: decodeUInt256(data[tupleStart + 32..<tupleStart + 64])) ?? -1
            let lengthStart = tupleStart + bytesOffset
            guard bytesOffset >= 0, lengthStart + 32 <= data.endIndex else {
                throw BlockchainClientError.decodingFailed(
                    reason: "aggregate3 response has an invalid return-data offset"
                )
            }
            let length = Int(exactly: decodeUInt256(data[lengthStart..<lengthStart + 32])) ?? -1
            let bytesStart = lengthStart + 32
            guard length >= 0, bytesStart + length <= data.endIndex else {
                throw BlockchainClientError.decodingFailed(reason: "aggregate3 response has truncated return data")
            }
            return (success, Data(data[bytesStart..<bytesStart + length]))
        }
    }

    /// Computes the 4-byte function selector for `signature` (e.g.
    /// `"balanceOf(address)"`) — Keccak-256(signature)'s first 4 bytes.
    ///
    /// - Parameter signature: The canonical function signature — name plus
    ///   parenthesized, comma-separated parameter types, no parameter names or
    ///   spaces (e.g. `"transfer(address,uint256)"`).
    public static func selector(_ signature: String) -> Data {
        ethereumFunctionSelector(signature: signature)
    }

    /// Encodes a contract call's data: `selector` followed by each of
    /// `parameters`' 32-byte ABI words, in order.
    public static func encodeCall(
        selector: Data,
        parameters: [EthereumABIValue] = []
    ) -> Data {
        selector + parameters.map(\.word).reduce(Data(), +)
    }

    /// Splits ABI return data into 32-byte words.
    ///
    /// - Note: Indexes off `data.startIndex`/`data.endIndex`, not `0`/
    ///   `data.count` — a `Data` slice (e.g. from `dropFirst(_:)`) retains
    ///   its original, non-zero-based indices, so offsetting from `0`
    ///   directly would index out of bounds for anything but a freshly
    ///   constructed `Data`.
    public static func words(_ data: Data) -> [Data] {
        stride(from: data.startIndex, to: data.endIndex, by: 32).map {
            data[$0..<Swift.min($0 + 32, data.endIndex)]
        }
    }

    /// Decodes a 32-byte word as an unsigned integer.
    public static func decodeUInt256(_ word: Data) -> BigUInt {
        BigUInt(word)
    }

    /// Decodes a 32-byte word as a two's-complement signed integer.
    public static func decodeInt256(_ word: Data) -> BigInt {
        let magnitude = BigUInt(word)

        guard let firstByte = word.first, firstByte & 0x80 != 0 else {
            return BigInt(magnitude)
        }

        return BigInt(magnitude) - (BigInt(1) << 256)
    }

    /// Decodes a 32-byte word as an address — its last 20 bytes.
    ///
    /// - Throws: ``WalletKitError/invalidAddress(reason:)`` if `word`'s
    ///   last 20 bytes aren't a valid address (can't happen for a
    ///   well-formed ABI word; `EthereumAddress(rawBytes:)` only rejects
    ///   the wrong byte count).
    public static func decodeAddress(_ word: Data) throws -> EthereumAddress {
        try EthereumAddress(rawBytes: word.suffix(20))
    }

    /// Decodes a 32-byte word as a boolean — non-zero is `true`.
    public static func decodeBool(_ word: Data) -> Bool {
        word.last != 0
    }

    /// Decodes ABI return data as a dynamic `string` — the
    /// offset/length/UTF-8-bytes encoding Solidity uses for a function
    /// that returns `string` (e.g. ERC-20's `name()`/`symbol()`).
    ///
    /// - Throws: ``BlockchainClientError/decodingFailed(reason:)`` if
    ///   `data` is too short, its offset or length point outside of
    ///   `data`, or the string bytes aren't valid UTF-8.
    public static func decodeString(_ data: Data) throws -> String {
        guard data.count >= 64,
              let offset = Int(exactly: decodeUInt256(data[data.startIndex..<data.startIndex + 32]))
        else {
            throw BlockchainClientError.decodingFailed(reason: "string return data too short or has an invalid offset")
        }

        let lengthStart = data.startIndex + offset
        guard lengthStart + 32 <= data.endIndex,
              let length = Int(exactly: decodeUInt256(data[lengthStart..<lengthStart + 32]))
        else {
            throw BlockchainClientError.decodingFailed(reason: "string return data has an invalid length offset")
        }

        let stringStart = lengthStart + 32
        guard stringStart + length <= data.endIndex else {
            throw BlockchainClientError.decodingFailed(reason: "string return data has an invalid length")
        }

        guard let string = String(data: data[stringStart..<stringStart + length], encoding: .utf8) else {
            throw BlockchainClientError.decodingFailed(reason: "string return data isn't valid UTF-8")
        }

        return string
    }

    /// Decodes ABI return data as a dynamic signed-integer array (e.g.
    /// `int56[]`/`int256[]`) — the offset/length/elements encoding
    /// Solidity uses for any dynamic array return, decoding each element
    /// as a full 32-byte two's-complement word regardless of its declared
    /// width (Uniswap V3's `observe(uint32[])` returns `int56[]
    /// tickCumulatives`, which — like any narrower-than-256-bit integer —
    /// is still ABI-encoded one word per element).
    ///
    /// - Throws: ``BlockchainClientError/decodingFailed(reason:)`` if
    ///   `data` is too short, or its offset or length point outside of
    ///   `data`.
    public static func decodeInt256Array(_ data: Data) throws -> [BigInt] {
        guard data.count >= 64,
              let offset = Int(exactly: decodeUInt256(data[data.startIndex..<data.startIndex + 32]))
        else {
            throw BlockchainClientError.decodingFailed(reason: "array return data too short or has an invalid offset")
        }

        let lengthStart = data.startIndex + offset
        guard lengthStart + 32 <= data.endIndex,
              let length = Int(exactly: decodeUInt256(data[lengthStart..<lengthStart + 32]))
        else {
            throw BlockchainClientError.decodingFailed(reason: "array return data has an invalid length offset")
        }

        let elementsStart = lengthStart + 32
        guard elementsStart + length * 32 <= data.endIndex else {
            throw BlockchainClientError.decodingFailed(reason: "array return data has an invalid length")
        }

        return (0..<length).map { index in
            let start = elementsStart + index * 32
            return decodeInt256(data[start..<start + 32])
        }
    }
}
