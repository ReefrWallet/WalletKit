// Spec-driven test for Docs/Design Specification/Clients/EthereumAddress.swift.
//
// Type-level tests for `EthereumAddress` itself — construction, EIP-55
// checksum handling, and error cases. Vector-driven tests that derive
// `EthereumAddress`es from real key material live in
// EthereumPKeySignerTests.

import Foundation
import Testing
@testable import WalletKit

// The EIP-155 spec's own worked example address (also present as the
// "eip155-canonical-example-key" vector in TestVectors/ethereum-address.json).
private let knownChecksummedAddress = "0x9d8A62f656a8d1615C1294fd71e9CFb3E4855A4F"

struct EthereumAddressTests {
    @Test func initFromStringRoundTripsItsChecksummedRepresentation() throws {
        let address = try EthereumAddress(string: knownChecksummedAddress)
        #expect(address.string == knownChecksummedAddress)
        #expect(address.checksummed == knownChecksummedAddress)
    }

    @Test func initFromStringAcceptsAllLowercase() throws {
        let address = try EthereumAddress(string: knownChecksummedAddress.lowercased())
        #expect(address.checksummed == knownChecksummedAddress)
    }

    @Test func initFromStringAcceptsAllUppercase() throws {
        let upperBody = knownChecksummedAddress.dropFirst(2).uppercased()
        let address = try EthereumAddress(string: "0x" + upperBody)
        #expect(address.checksummed == knownChecksummedAddress)
    }

    @Test func initFromStringThrowsOnABadChecksum() {
        // One letter's case flipped from `knownChecksummedAddress` (still
        // mixed-case, so checksum validation applies and must fail).
        let bad = "0x9d8a62f656a8d1615C1294fd71e9CFb3E4855A4F"
        #expect(throws: WalletKitError.self) {
            _ = try EthereumAddress(string: bad)
        }
    }

    @Test func initFromStringThrowsOnTheWrongLength() {
        #expect(throws: WalletKitError.self) {
            _ = try EthereumAddress(string: "0x1234")
        }
    }

    @Test func initFromStringThrowsOnMissingPrefix() {
        #expect(throws: WalletKitError.self) {
            _ = try EthereumAddress(string: String(knownChecksummedAddress.dropFirst(2)))
        }
    }

    @Test func initFromRawBytesThrowsOnTheWrongByteCount() {
        #expect(throws: WalletKitError.self) {
            _ = try EthereumAddress(rawBytes: Data(repeating: 0, count: 19))
        }
    }

    @Test func rawBytesRoundTripsThroughInitFromRawBytes() throws {
        let parsed = try EthereumAddress(string: knownChecksummedAddress)
        #expect(parsed.rawBytes.count == 20)

        let rebuilt = try EthereumAddress(rawBytes: parsed.rawBytes)
        #expect(rebuilt == parsed)
        #expect(rebuilt.checksummed == knownChecksummedAddress)
    }

    @Test func equalityComparesRawBytesRegardlessOfInputCasing() throws {
        let mixedCase = try EthereumAddress(string: knownChecksummedAddress)
        let allLowercase = try EthereumAddress(string: knownChecksummedAddress.lowercased())
        #expect(mixedCase == allLowercase)
    }
}
