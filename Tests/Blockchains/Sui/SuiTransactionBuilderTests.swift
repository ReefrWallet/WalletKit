// Integration tests for SuiTransactionBuilder against a real, running
// local Sui node (SuiNode.swift). Mirrors SuiLocalnetTests.swift's
// "real infrastructure, not a mock" philosophy: derive a wallet, fund
// it from the faucet, use the builder to produce unsigned bytes, sign
// them with SuiPKeySigner, broadcast, and confirm balances changed by
// exactly the expected amount.
//
// `.localNode`: if `mise`/`sui` can't start, the suite fails loudly
// locally; it isn't run in CI at all (see LocalNodeTrait.swift).

import BigInt
import Foundation
import Testing
import WalletKit
import WalletKitTesting

// `.serialized`: see SuiLocalnetTests.swift — each test spins up its own
// full local `sui` validator, and running several concurrently causes
// enough CPU contention to blow past the time limit. The 2-minute limit is
// per test (measured 5–6s on a quiet machine): it must cover `SuiNodeGate`
// queueing plus startup, see SuiLocalnetTests.swift.
@Suite(.timeLimit(.minutes(2)), .serialized, .localNode)
struct SuiTransactionBuilderTests {
    // MARK: - Native SUI transfer

    @Test func builderProducesValidNativeSUITransferThatChangesBalances() async throws {
        let node = try await SuiNode.start()
        defer { node.stop() }

        let vectors = loadSuiEd25519AddressVectors()
        let signerA = try makeSuiSigner(privateKeyHex: vectors[0].privateKey)
        let walletA = try signerA.address()
        let walletB = try makeSuiSigner(privateKeyHex: vectors[1].privateKey).address()

        let client = SuiGRPCClient(host: "127.0.0.1", port: Int(node.rpcPort), useTLS: false)
        let builder = SuiTransactionBuilder(client: client)

        try await node.faucet(walletA)
        let beforeA = try await client.nativeBalance(of: walletA)
        let beforeB = try await client.nativeBalance(of: walletB)
        #expect(beforeA > 0)
        #expect(beforeB == 0)

        let transferAmount: UInt64 = 500_000_000 // 0.5 SUI

        let txBytes = try await builder.buildTransfer(
            sender: walletA, recipient: walletB, amount: BigUInt(transferAmount), token: nil
        )

        let signature = try await signerA.sign(transaction: txBytes)
        let digest = try await client.broadcast(transactionData: txBytes, signature: signature)
        #expect(!digest.isEmpty)

        let effects = try await node.waitForEffects(digest)
        #expect(effects.status.success, "native SUI transfer should succeed")

        let afterB = try await node.waitForBalanceChange(of: walletB, from: beforeB)
        #expect(afterB == beforeB + transferAmount)

        let afterA = try await node.waitForBalanceChange(of: walletA, from: beforeA)
        // A paid transfer + gas; verify the direction only.
        #expect(afterA < beforeA - transferAmount)
    }

    // MARK: - Multi-coin gas payment (fragmented SUI)

    /// Exercises the builder's coin-selection logic when a single SUI coin
    /// cannot cover `amount + gasBudget`. After two faucet calls walletA holds
    /// two separate coin objects; requesting more than the largest single
    /// coin's balance forces the builder to select both as gasPayment.
    ///
    /// This validates the P1 fix for fragmented SUI balances and the
    /// two-pass (simulation → real) budget pipeline.
    ///
    /// - Note: The arbitrary-coin path (`buildTokenTransfer`) uses the same
    ///   coin-selection and simulation logic but requires a non-native Sui
    ///   token, which demands a published Move package. Full token-path
    ///   coverage is deferred to an environment where such a package is
    ///   available.
    @Test func builderSelectsMultipleGasCoinsWhenSingleCoinIsInsufficient() async throws {
        let node = try await SuiNode.start()
        defer { node.stop() }

        let vectors = loadSuiEd25519AddressVectors()
        let signerA = try makeSuiSigner(privateKeyHex: vectors[0].privateKey)
        let walletA = try signerA.address()
        let walletB = try makeSuiSigner(privateKeyHex: vectors[1].privateKey).address()

        let client = SuiGRPCClient(host: "127.0.0.1", port: Int(node.rpcPort), useTLS: false)
        let builder = SuiTransactionBuilder(client: client)

        // Two faucet calls each wait for their own SUI coin object to index.
        try await node.faucet(walletA)
        try await node.faucet(walletA)

        let coins = try await node.suiCoins(of: walletA)
        try #require(coins.count >= 2)

        // Request one MIST more than the largest single coin's balance so the
        // builder must pick both coins as gasPayment (gas coins double as the
        // transfer source in the native SUI PTB).
        let transferAmount = coins[0].balance + 1

        let beforeB = try await client.nativeBalance(of: walletB)
        let txBytes = try await builder.buildTransfer(
            sender: walletA, recipient: walletB, amount: BigUInt(transferAmount), token: nil
        )

        let signature = try await signerA.sign(transaction: txBytes)
        let digest = try await client.broadcast(transactionData: txBytes, signature: signature)
        #expect(!digest.isEmpty)

        let effects = try await node.waitForEffects(digest)
        #expect(effects.status.success, "native SUI transfer using multiple gas coins should succeed")

        let afterB = try await node.waitForBalanceChange(of: walletB, from: beforeB)
        #expect(afterB == beforeB + transferAmount)
    }
}

// MARK: - Helpers (local to this file)

private struct SuiAddressVector: Decodable {
    let label: String
    let scheme: String
    let privateKey: String
    let address: String
}

private func loadSuiEd25519AddressVectors() -> [SuiAddressVector] {
    let url = Bundle.module.url(forResource: "sui-address", withExtension: "json")!
    // swiftlint:disable:next force_try
    let data = try! Data(contentsOf: url)
    // swiftlint:disable:next force_try
    let vectors = try! JSONDecoder().decode([SuiAddressVector].self, from: data)
    return vectors.filter { $0.scheme == "ed25519" }
}

private func makeSuiSigner(privateKeyHex: String) throws -> SuiPKeySigner {
    let hex = privateKeyHex.hasPrefix("0x") ? String(privateKeyHex.dropFirst(2)) : privateKeyHex
    var data = Data(capacity: hex.count / 2)
    var index = hex.startIndex
    while index < hex.endIndex {
        let next = hex.index(index, offsetBy: 2, limitedBy: hex.endIndex) ?? hex.endIndex
        data.append(UInt8(hex[index..<next], radix: 16)!)
        index = next
    }

    let privateKey = try PrivateKey(curve: .ed25519, rawBytes: data)
    return try SuiPKeySigner(
        curve: .ed25519,
        privateKey: privateKey,
        derivationPath: TestAccountFactory.slip10Path(coinType: 784)
    )
}
