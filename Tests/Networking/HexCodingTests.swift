// Tests for Sources/Static/Networking/HexCoding.swift: the `Data`
// `0x`-prefixed hex encode/decode helpers backing JSONRPCClient and
// EthereumRPCClient's request/response bodies.

import Foundation
import Testing
@testable import WalletKit

struct HexCodingTests {
    @Test func hexEncodedProducesA0xPrefixedLowercaseString() {
        #expect(Data([0xDE, 0xAD, 0xBE, 0xEF]).hexEncoded == "0xdeadbeef")
    }

    @Test func hexEncodedOfEmptyDataIsJustThePrefix() {
        #expect(Data().hexEncoded == "0x")
    }

    @Test func initHexStringDecodesA0xPrefixedString() throws {
        #expect(try Data(hexString: "0xdeadbeef") == Data([0xDE, 0xAD, 0xBE, 0xEF]))
    }

    @Test func initHexStringAcceptsABareStringWithNoPrefix() throws {
        #expect(try Data(hexString: "deadbeef") == Data([0xDE, 0xAD, 0xBE, 0xEF]))
    }

    @Test func initHexStringIsCaseInsensitive() throws {
        #expect(try Data(hexString: "0xDEADBEEF") == Data([0xDE, 0xAD, 0xBE, 0xEF]))
    }

    @Test func initHexStringOfJustThePrefixIsEmptyData() throws {
        #expect(try Data(hexString: "0x") == Data())
    }

    @Test func initHexStringThrowsOnAnOddNumberOfDigits() {
        #expect(throws: BlockchainClientError.self) {
            _ = try Data(hexString: "0xabc")
        }
    }

    @Test func initHexStringThrowsOnNonHexCharacters() {
        #expect(throws: BlockchainClientError.self) {
            _ = try Data(hexString: "0xzzzz")
        }
    }

    @Test func hexEncodedRoundTripsThroughInitHexString() throws {
        let original = Data([0x00, 0x01, 0x7F, 0x80, 0xFF])
        #expect(try Data(hexString: original.hexEncoded) == original)
    }
}
