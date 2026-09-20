// Tests for Sources/Static/Blockchains/Ethereum/EthereumENS.swift —
// `namehash(_:)`'s EIP-137 computation. The well-known values below were
// computed independently from this Swift implementation, straight from
// `alloy_primitives::keccak256` in a scratch Rust test (see
// Rust/walletkit-ffi/src/blockchain_clients/ethereum_abi.rs's Keccak-256
// tests for that primitive's own well-known-value coverage), so this
// verifies the namehash algorithm itself, not just internal consistency.

import Foundation
import Testing
@testable import WalletKit

struct EthereumENSTests {
    @Test func namehashOfTheEmptyNameIsAllZeroes() {
        #expect(EthereumENS.namehash("") == Data(repeating: 0, count: 32))
    }

    @Test func namehashOfEthMatchesTheWellKnownValue() throws {
        let expected = try Data(hexString: "0x93cdeb708b7545dc668eb9280176169d1c33cfd8ed6f04690a0bcc88a93fc4ae")
        #expect(EthereumENS.namehash("eth") == expected)
    }

    @Test func namehashOfEthUsdDataEthMatchesTheWellKnownValue() throws {
        let expected = try Data(hexString: "0xf599f4cd075a34b92169cf57271da65a7a936c35e3f31e854447fbb3e7eb736d")
        #expect(EthereumENS.namehash("eth-usd.data.eth") == expected)
    }

    @Test func namehashOfBtcUsdDataEthMatchesTheWellKnownValue() throws {
        let expected = try Data(hexString: "0x792e87d95b15420d569dda3b565785db994e935588db932d66111a8bc6e4c755")
        #expect(EthereumENS.namehash("btc-usd.data.eth") == expected)
    }

    @Test func namehashIsThirtyTwoBytesLong() {
        #expect(EthereumENS.namehash("eth-usd.data.eth").count == 32)
    }

    @Test func namehashDiffersForDifferentBaseSymbols() {
        #expect(EthereumENS.namehash("eth-usd.data.eth") != EthereumENS.namehash("btc-usd.data.eth"))
    }
}
