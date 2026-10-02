// Integration test for
// Sources/Static/Blockchains/Sui/SuiGRPCClient.swift against a real,
// running local Sui node (`sui start --with-faucet`) — nothing before this
// exercised the full path end-to-end: derive a wallet, fund it from the
// faucet, sign a real transaction, broadcast it, and confirm the chain's
// own balances changed by exactly the expected amount. Mirrors the "real
// infrastructure, not a mock" testing philosophy EthereumAnvilTests.swift
// already established for Ethereum, and the "Testable against
// pre-configured test wallets ... for every supported blockchain" goal in
// Docs/Overview.md — using the same private keys
// TestVectors/sui-address.json's other tests already use.
//
// `sui start` is run via SuiNode.swift (`mise x sui -- sui ...`), which
// auto-installs the pinned `sui` on first use the same way this repo's
// other mise-managed tools already do. There's no `withKnownIssue` gating
// here, unlike SuiGRPCClientTests.swift's public-testnet suite: if
// `mise`/`sui` can't find/run it, or the node never becomes ready, this
// fails loudly rather than skipping quietly — the same choice
// EthereumAnvilTests.swift makes for Anvil.

import Foundation
import Testing
import WalletKit
import WalletKitTesting

private struct SuiAddressVector: Decodable {
    let label: String
    let scheme: String
    let privateKey: String
    let address: String
}

private func loadEd25519AddressVectors() -> [SuiAddressVector] {
    let url = Bundle.module.url(forResource: "sui-address", withExtension: "json")!
    // swiftlint:disable:next force_try
    let data = try! Data(contentsOf: url)
    // swiftlint:disable:next force_try
    let vectors = try! JSONDecoder().decode([SuiAddressVector].self, from: data)
    return vectors.filter { $0.scheme == "ed25519" }
}

private extension String {
    /// Decodes a `0x`-prefixed (or bare) hex string, as used throughout the
    /// Sui test vector files.
    var hexDecoded: Data {
        let hex = hasPrefix("0x") ? String(dropFirst(2)) : self
        var data = Data(capacity: hex.count / 2)
        var index = hex.startIndex
        while index < hex.endIndex {
            let next = hex.index(index, offsetBy: 2, limitedBy: hex.endIndex) ?? hex.endIndex
            data.append(UInt8(hex[index..<next], radix: 16)!)
            index = next
        }

        return data
    }
}

private func makeSigner(privateKeyHex: String) throws -> SuiPKeySigner {
    let privateKey = try PrivateKey(curve: .ed25519, rawBytes: privateKeyHex.hexDecoded)
    return try SuiPKeySigner(
        curve: .ed25519,
        privateKey: privateKey,
        derivationPath: TestAccountFactory.slip10Path(coinType: 784)
    )
}

/// Splits `signer`'s largest owned SUI coin, transfers `amount` of it to
/// `recipient`, and returns the transaction's actual gas charge —
/// `computationCost + storageCost - storageRebate`, read from the
/// broadcast transaction's own effects rather than assumed from
/// `gasBudget`, so the caller's balance assertion can be exact rather than
/// a bound. Mirrors `EthereumAnvilTests.sendAndConfirm`'s role.
private func send(
    client: SuiGRPCClient,
    node: SuiNode,
    signer: SuiPKeySigner,
    recipient: SuiAddress,
    amount: UInt64
) async throws -> UInt64 {
    let sender = try signer.address()
    let gasCoin = try await node.largestSuiCoin(of: sender)
    let gasPrice = try await node.referenceGasPrice()

    let transaction = UnsignedSuiTransaction(
        sender: sender,
        transfers: [(recipient: recipient, amount: amount)],
        gasPayment: [gasCoin],
        gasOwner: sender,
        gasPrice: gasPrice,
        gasBudget: 10_000_000
    )
    let bcs = transaction.transactionDataBcs
    let signature = try await signer.sign(transaction: bcs)
    let digest = try await client.broadcast(transactionData: bcs, signature: signature)
    #expect(!digest.isEmpty, "broadcast should return a real digest now that read_mask requests it")

    let effects = try await node.waitForEffects(digest)
    #expect(effects.status.success, "transaction from \(sender.string) should have succeeded")

    let gasUsed = effects.gasUsed
    let charge = Int64(gasUsed.computationCost) + Int64(gasUsed.storageCost) - Int64(gasUsed.storageRebate)
    return UInt64(charge)
}

// `.serialized`: each test spins up its own full local `sui` validator
// process. Running several concurrently (Swift Testing's default) makes
// them compete for CPU badly enough that a normally-fast test can blow
// past the 1-minute time limit — observed directly running this suite
// alongside SuiTransactionBuilderTests, where a test that passes in ~15s
// alone failed on "exceeded execution time allowance" when six such
// validators were starting at once.
@Suite(.timeLimit(.minutes(1)), .serialized)
struct SuiLocalnetTests {
    // MARK: - Fee estimation

    /// Rates-only: `estimateFee(for: nil)` returns the epoch's reference gas
    /// price with no per-transaction fields.
    @Test func estimateFeeRatesOnlyMatchesTheNodeReferenceGasPrice() async throws {
        let node = try await SuiNode.start()
        defer { node.stop() }

        let client = SuiGRPCClient(host: "127.0.0.1", port: Int(node.rpcPort), useTLS: false)
        let estimate = try await client.estimateFee(for: nil)
        let referenceGasPrice = try await node.referenceGasPrice()

        #expect(estimate.gasPrice == BigUInt(referenceGasPrice))
        #expect(estimate.maxFeePerGas == nil, "Sui has no EIP-1559 max fee")
        #expect(estimate.maxPriorityFeePerGas == nil, "Sui has no EIP-1559 priority fee")
        #expect(estimate.gasLimit == nil, "rates-only: no per-tx gas limit")
        #expect(estimate.estimatedFee == nil, "rates-only: no per-tx fee")
    }

    /// Per-tx estimate for a native SUI transfer: the fee is positive and
    /// the gas price matches the reference gas price.
    @Test func estimateFeeForANativeSUITransferReturnsAPositiveFee() async throws {
        let node = try await SuiNode.start()
        defer { node.stop() }

        let vectors = loadEd25519AddressVectors()
        let signerA = try makeSigner(privateKeyHex: vectors[0].privateKey)
        let walletA = try signerA.address()
        let walletB = try makeSigner(privateKeyHex: vectors[1].privateKey).address()

        let client = SuiGRPCClient(host: "127.0.0.1", port: Int(node.rpcPort), useTLS: false)
        try await node.faucet(walletA)

        let gasCoin = try await node.largestSuiCoin(of: walletA)
        let gasPrice = try await node.referenceGasPrice()

        let tx = UnsignedSuiTransaction(
            sender: walletA,
            transfers: [(recipient: walletB, amount: 1_000_000_000)],
            gasPayment: [gasCoin],
            gasOwner: walletA,
            gasPrice: gasPrice,
            gasBudget: 10_000_000
        )

        let estimate = try await client.estimateFee(
            for: FeeEstimateRequest(data: tx.transactionDataBcs)
        )

        #expect(estimate.gasPrice == BigUInt(gasPrice))
        let estimatedFee = try #require(estimate.estimatedFee)
        #expect(estimatedFee > 0)
    }

    /// Per-tx estimate for a coin-object transfer (the PTB shape used for any
    /// arbitrary `Coin<T>`, e.g. USDC). Funds wallet A twice via the faucet
    /// to obtain two separate SUI coin objects: one for gas, one to transfer
    /// (reusing SUI to exercise the PTB shape, which is identical regardless
    /// of coin type).
    @Test func estimateFeeForACoinObjectTransferReturnsAPositiveFee() async throws {
        let node = try await SuiNode.start()
        defer { node.stop() }

        let vectors = loadEd25519AddressVectors()
        let signerA = try makeSigner(privateKeyHex: vectors[0].privateKey)
        let walletA = try signerA.address()
        let walletB = try makeSigner(privateKeyHex: vectors[1].privateKey).address()

        let client = SuiGRPCClient(host: "127.0.0.1", port: Int(node.rpcPort), useTLS: false)

        // Two faucet calls give two separate coin objects: one for gas and
        // one to transfer. `faucet(_:)` returns only once the new object is
        // indexed, so both are available before we continue.
        try await node.faucet(walletA)
        try await node.faucet(walletA)

        let coins = try await node.suiCoins(of: walletA)
        try #require(coins.count >= 2)

        let gasCoin = coins[0].reference    // largest — used for gas
        let coinToTransfer = coins[1]       // second — the object being transferred
        let gasPrice = try await node.referenceGasPrice()

        let tx = UnsignedCoinObjectTransfer(
            sender: walletA,
            coinObject: coinToTransfer.reference,
            recipient: walletB,
            gasPayment: [gasCoin],
            gasOwner: walletA,
            gasPrice: gasPrice,
            gasBudget: 10_000_000
        )

        let estimate = try await client.estimateFee(
            for: FeeEstimateRequest(data: tx.transactionDataBcs)
        )

        #expect(estimate.gasPrice == BigUInt(gasPrice))
        let estimatedFee = try #require(estimate.estimatedFee)
        #expect(estimatedFee > 0)
    }

    // MARK: - Transfer

    @Test func twoWalletsExchangeSUIOnALocalNetwork() async throws {
        let node = try await SuiNode.start()
        defer { node.stop() }

        let vectors = loadEd25519AddressVectors()
        let signerA = try makeSigner(privateKeyHex: vectors[0].privateKey)
        let signerB = try makeSigner(privateKeyHex: vectors[1].privateKey)
        let walletA = try signerA.address()
        let walletB = try signerB.address()

        let client = SuiGRPCClient(host: "127.0.0.1", port: Int(node.rpcPort), useTLS: false)

        // A freshly-regenesis'd network makes "unfunded means exactly
        // zero" deterministic — the assertion SuiGRPCClientTests' live
        // testnet suite explicitly can't make.
        #expect(try await client.nativeBalance(of: walletB) == 0)

        try await node.faucet(walletA)
        let beforeA = try await client.nativeBalance(of: walletA)
        #expect(beforeA > 0)
        let beforeB: UInt64 = 0

        let transferAmount: UInt64 = 1_000_000_000 // 1 SUI
        let feeAtoB = try await send(
            client: client, node: node, signer: signerA, recipient: walletB, amount: transferAmount
        )

        let afterA = try await node.waitForBalanceChange(of: walletA, from: beforeA)
        let afterB = try await node.waitForBalanceChange(of: walletB, from: beforeB)
        #expect(afterA == beforeA - transferAmount - feeAtoB)
        #expect(afterB == beforeB + transferAmount)

        // Transfer part of it back, B -> A. B pays gas out of the coin it
        // just received, proving that coin is genuinely spendable.
        let returnAmount: UInt64 = 500_000_000 // 0.5 SUI
        let feeBtoA = try await send(
            client: client, node: node, signer: signerB, recipient: walletA, amount: returnAmount
        )

        let finalB = try await node.waitForBalanceChange(of: walletB, from: afterB)
        let finalA = try await node.waitForBalanceChange(of: walletA, from: afterA)
        #expect(finalB == afterB - returnAmount - feeBtoA)
        #expect(finalA == afterA + returnAmount)
    }
}
