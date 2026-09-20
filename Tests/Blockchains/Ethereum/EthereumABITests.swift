// Tests for Sources/Static/Blockchains/Ethereum/EthereumABI.swift: static-
// word call-data encoding and return-data decoding. `selector(_:)`'s actual
// Keccak-256 computation crosses the FFI boundary into
// `ethereum_function_selector` and is exhaustively tested there (see
// Rust/walletkit-ffi/src/blockchain_clients/ethereum_abi.rs); the test here
// just confirms the Swift wrapper calls through correctly.

import BigInt
import Foundation
import Testing
@testable import WalletKit

// swiftlint:disable:next force_try
private let someAddress = try! EthereumAddress(rawBytes: Data((1...20).map(UInt8.init)))

/// Left-pads `data` to one 32-byte ABI word.
private func word(_ data: Data) -> Data {
    Data(repeating: 0, count: 32 - data.count) + data
}

/// A 32-byte ABI word encoding `value` as an unsigned big-endian integer.
private func word(_ value: BigUInt) -> Data {
    word(value.serialize())
}

/// A 32-byte ABI word encoding `value` as a two's-complement signed integer
/// — computed independently of `EthereumABI.decodeInt256`.
private func word(_ value: BigInt) -> Data {
    guard value.sign == .minus else { return word(value.magnitude) }
    return word((BigUInt(1) << 256) - value.magnitude)
}

struct EthereumABITests {
    // MARK: - selector

    @Test func selectorMatchesTheWellKnownERC20BalanceOfValue() {
        #expect(EthereumABI.selector("balanceOf(address)") == Data([0x70, 0xa0, 0x82, 0x31]))
    }

    // MARK: - encodeCall

    @Test func encodeCallWithNoParametersIsJustTheSelector() {
        let selector = Data([0xfe, 0xaf, 0x96, 0x8c])
        #expect(EthereumABI.encodeCall(selector: selector) == selector)
    }

    @Test func encodeCallAppendsEachParametersWordAfterTheSelector() {
        let selector = Data([0x70, 0xa0, 0x82, 0x31])
        let data = EthereumABI.encodeCall(selector: selector, parameters: [.address(someAddress), .uint256(42)])

        #expect(data.count == 4 + 32 + 32)
        #expect(data.prefix(4) == selector)
        #expect(EthereumABI.words(data.dropFirst(4)) == [
            Data(repeating: 0, count: 12) + someAddress.rawBytes,
            Data(repeating: 0, count: 31) + Data([42])
        ])
    }

    // MARK: - EthereumABIValue.word

    @Test func addressWordIsLeftPaddedWithTwelveZeroBytes() {
        #expect(EthereumABIValue.address(someAddress).word == Data(repeating: 0, count: 12) + someAddress.rawBytes)
    }

    @Test func uint256WordIsLeftPaddedBigEndian() {
        #expect(EthereumABIValue.uint256(0).word == Data(repeating: 0, count: 32))
        #expect(EthereumABIValue.uint256(1).word == Data(repeating: 0, count: 31) + Data([1]))
        #expect(EthereumABIValue.uint256(256).word == Data(repeating: 0, count: 30) + Data([1, 0]))
    }

    @Test func boolWordIsZeroOrOneInTheLastByte() {
        #expect(EthereumABIValue.bool(false).word == Data(repeating: 0, count: 32))
        #expect(EthereumABIValue.bool(true).word == Data(repeating: 0, count: 31) + Data([1]))
    }

    @Test func bytes32WordIsThePassedDataUnchanged() {
        let node = Data(repeating: 0xAB, count: 32)
        #expect(EthereumABIValue.bytes32(node).word == node)
    }

    // MARK: - words

    @Test func wordsSplitsExactMultiplesOfThirtyTwoBytesEvenly() {
        let data = Data(repeating: 0xAB, count: 64)
        let words = EthereumABI.words(data)
        #expect(words.count == 2)
        #expect(words.allSatisfy { $0.count == 32 })
    }

    @Test func wordsReturnsAShortFinalChunkForNonMultipleLengths() {
        let data = Data(repeating: 0xAB, count: 40)
        let words = EthereumABI.words(data)
        #expect(words.map(\.count) == [32, 8])
    }

    @Test func wordsOfEmptyDataIsEmpty() {
        #expect(EthereumABI.words(Data()).isEmpty)
    }

    @Test func wordsAcceptsANonZeroBasedSliceWithoutCrashing() {
        // `Data` slices (e.g. from `dropFirst`) retain their original,
        // non-zero-based indices — `words` must index off
        // `startIndex`/`endIndex`, not assume `0`.
        let full = Data(repeating: 0, count: 4) + Data(repeating: 0xAB, count: 32)
        #expect(EthereumABI.words(full.dropFirst(4)) == [Data(repeating: 0xAB, count: 32)])
    }

    // MARK: - decodeUInt256

    @Test func decodeUInt256RoundTripsAKnownValue() {
        let value = BigUInt(1) << 200
        let word = Data(repeating: 0, count: 32 - value.serialize().count) + value.serialize()
        #expect(EthereumABI.decodeUInt256(word) == value)
    }

    // MARK: - decodeInt256

    @Test func decodeInt256OfAllZeroesIsZero() {
        #expect(EthereumABI.decodeInt256(Data(repeating: 0, count: 32)) == 0)
    }

    @Test func decodeInt256WithAClearHighBitIsPositive() {
        var word = Data(repeating: 0, count: 32)
        word[31] = 42
        #expect(EthereumABI.decodeInt256(word) == BigInt(42))
    }

    @Test func decodeInt256WithASetHighBitIsNegativeTwosComplement() {
        // -1, all bits set.
        #expect(EthereumABI.decodeInt256(Data(repeating: 0xFF, count: 32)) == BigInt(-1))
    }

    // MARK: - decodeAddress

    @Test func decodeAddressExtractsTheLastTwentyBytes() throws {
        let word = Data(repeating: 0, count: 12) + someAddress.rawBytes
        #expect(try EthereumABI.decodeAddress(word) == someAddress)
    }

    // MARK: - decodeBool

    @Test func decodeBoolTreatsAZeroLastByteAsFalse() {
        #expect(EthereumABI.decodeBool(Data(repeating: 0, count: 32)) == false)
    }

    @Test func decodeBoolTreatsANonZeroLastByteAsTrue() {
        var word = Data(repeating: 0, count: 32)
        word[31] = 1
        #expect(EthereumABI.decodeBool(word) == true)
    }

    // MARK: - decodeInt256Array

    @Test func decodeInt256ArrayDecodesEachElementAsATwosComplementWord() throws {
        let elements: [BigInt] = [5, -3]
        let data = word(BigUInt(32)) + word(BigUInt(elements.count)) + word(elements[0]) + word(elements[1])
        #expect(try EthereumABI.decodeInt256Array(data) == elements)
    }

    @Test func decodeInt256ArrayOfZeroLengthIsEmpty() throws {
        let data = word(BigUInt(32)) + word(BigUInt(0))
        #expect(try EthereumABI.decodeInt256Array(data).isEmpty)
    }

    @Test func decodeInt256ArrayThrowsOnDataTooShortForTheOffsetWord() {
        #expect(throws: BlockchainClientError.self) {
            _ = try EthereumABI.decodeInt256Array(Data(repeating: 0, count: 32))
        }
    }

    @Test func decodeInt256ArrayThrowsWhenTheDeclaredLengthExceedsAvailableData() {
        // Declares 2 elements but supplies none.
        let data = word(BigUInt(32)) + word(BigUInt(2))
        #expect(throws: BlockchainClientError.self) {
            _ = try EthereumABI.decodeInt256Array(data)
        }
    }

    // MARK: - Multicall3 aggregate3

    @Test func encodeAggregate3BuildsDynamicCallArray() {
        let data = EthereumABI.encodeAggregate3([
            (target: someAddress, allowFailure: true, callData: Data([0x01, 0x02]))
        ])

        #expect(data.prefix(4) == EthereumABI.selector("aggregate3((address,bool,bytes)[])"))
        #expect(data.count == 4 + 32 + 32 + 32 + 96 + 32 + 32)
    }

    @Test func decodeAggregate3ReadsSuccessFlagsAndReturnData() throws {
        let first = Data(repeating: 0, count: 31) + Data([1])
            + word(BigUInt(64)) + word(BigUInt(32)) + Data(repeating: 0, count: 31) + Data([7])
        let second = Data(repeating: 0, count: 32)
            + word(BigUInt(64)) + word(BigUInt(0))
        let data = word(BigUInt(32)) + word(BigUInt(2))
            + word(BigUInt(96)) + word(BigUInt(224)) + first + second

        let results = try EthereumABI.decodeAggregate3(data)
        #expect(results.count == 2)
        #expect(results[0].success)
        #expect(results[0].returnData == word(BigUInt(7)))
        #expect(results[1].success == false)
        #expect(results[1].returnData.isEmpty)
    }
}
