// Runs the send flow end to end against a real `bitcoind -regtest` node
// fronted by `electrs` (see `BitcoinNode`), once for each backend
// (`ElectrumBackend`/`EsploraBackend`) — parametrized rather than
// duplicated, so both are asserted to behave identically against the same
// chain state. `BitcoinTransactionBuilderTests` already exhaustively
// covers the build→sign→finalize→broadcast wiring against a mock backend;
// this suite instead exercises the two real transports' balance/history/
// UTXO/broadcast plumbing and gap-limit address discovery.
//
// `.serialized`: two concurrently-provisioned `BitcoinNode`s would each
// try to `cargo build`/download into the same shared cache directory on a
// machine that hasn't run this suite before — see `BitcoinNode`'s own doc
// comment for why that cache is shared rather than per-test.

import BigInt
import Foundation
import Testing
@testable import WalletKit
import WalletKitRust
import WalletKitTesting

enum RegtestBackendKind: String, CustomTestStringConvertible {
    case electrum
    case esplora

    var testDescription: String { rawValue }
}

/// Derives a fresh, real (never hand-typed) BIP-84 regtest account —
/// mirrors `BitcoinTransactionBuilderTests`' own `makeAccount` helper.
private func makeRegtestAccount() throws -> (
    descriptor: BitcoinDescriptor, seed: Seed, derivationPath: DerivationPath
) {
    let seed = Mnemonic.generate().toSeed()
    let masterKey = try seed.masterKey(curve: .secp256k1)
    let masterFingerprint = try BitcoinDescriptor.fingerprint(of: masterKey.publicKey)

    let accountDerivationPath = try DerivationPath.bitcoinAccount(
        network: .regtest, scriptType: .p2wpkh, accountIndex: 0
    )
    let accountKey = try masterKey.derive(accountDerivationPath)
    let accountPathText = String(accountDerivationPath.string.dropFirst(2)) // drop the leading "m/".

    let descriptor = try BitcoinDescriptor(
        xpub: accountKey.serializedPublic(),
        scriptType: .p2wpkh,
        network: .regtest,
        masterFingerprint: masterFingerprint,
        accountPath: accountPathText
    )
    return (descriptor, seed, accountDerivationPath)
}

private func makeClient(node: BitcoinNode, backend: RegtestBackendKind) -> BitcoinClient {
    switch backend {
    case .electrum:
        return BitcoinClient(electrumHost: node.electrumHost, port: node.electrumPort, useTLS: false)
    case .esplora:
        return BitcoinClient(esploraEndpoint: node.esploraEndpoint)
    }
}

@Suite(.serialized)
struct BitcoinRegtestTests {
    @Test(arguments: [RegtestBackendKind.electrum, .esplora])
    func fundSendMineAndConfirmBalanceNetsOut(backend: RegtestBackendKind) async throws {
        let node = try await BitcoinNode.start()
        defer { node.stop() }

        let (sender, senderSeed, senderPath) = try makeRegtestAccount()
        let (recipient, _, _) = try makeRegtestAccount()

        let receiveAddress = try sender.deriveAddress(chain: 0, index: 0)
        let fundingSats: UInt64 = 5_000_000
        _ = try await node.fund(address: receiveAddress.string(), amountSats: fundingSats)

        let client = makeClient(node: node, backend: backend)

        let balanceAfterFunding = try await client.getNativeBalance(sender)
        #expect(balanceAfterFunding == BigUInt(fundingSats))

        let history = try await client.transactionHistory(
            sender, request: BlockchainTransactionHistoryRequest(direction: .descending)
        )
        #expect(!history.transactions.isEmpty)

        // `TransactionSyncService` needs `head` to establish
        // `currentHead` and start forward polling — without it, forward
        // sync stays stalled forever after backfill (regression guard).
        let head = try #require(history.head)
        #expect(head > 0)

        let fundingTxid = try #require(history.transactions.first).identifier
        let fundingHeight = try #require(history.transactions.first?.blockHeight)
        try await expectNoHistoryBeforeFunding(client: client, sender: sender, fundingHeight: fundingHeight)

        let recipientAddress = try recipient.deriveAddress(chain: 0, index: 0)
        let recipientDestination = try BitcoinDescriptor(address: recipientAddress.string(), network: .regtest)

        let sendSats: UInt64 = 1_000_000
        let feeRateSatPerVByte: UInt64 = 10 // fixed, deterministic — a fresh regtest node has no real fee history.
        let builder = BitcoinTransactionBuilder(client: client)
        let psbt = try await builder.buildTransfer(
            sender: sender,
            recipient: recipientDestination,
            amount: BigUInt(sendSats),
            token: nil,
            options: [.bitcoinFeeOverride(feeRateSatPerVByte: feeRateSatPerVByte)]
        )

        let signer = try BitcoinPKeySigner(descriptor: sender, seed: senderSeed, derivationPath: senderPath)
        let finalized = try await signer.sign(transaction: psbt)
        let fee = try bitcoinPsbtFee(psbt: psbt)

        let txid = try await client.broadcast(transaction: psbt, signature: finalized)
        #expect(txid.count == 64)

        try await node.mine(1, to: try node.newWalletAddress())

        let recipientBalance = try await client.getNativeBalance(recipientDestination)
        #expect(recipientBalance == BigUInt(sendSats))

        // The change address (chain 1, index 0) should now be used, and
        // the sender's total balance should net out to funding − send −
        // fee — proving both coin selection and change-address discovery
        // worked against this real backend, not just a mock.
        let senderBalanceAfterSend = try await client.getNativeBalance(sender)
        #expect(senderBalanceAfterSend == BigUInt(fundingSats - sendSats - fee))

        let changeAddress = try sender.deriveAddress(chain: 1, index: 0)
        let changeDescriptor = try BitcoinDescriptor(address: changeAddress.string(), network: .regtest)
        #expect(try await client.isActiveAccount(changeDescriptor))

        try await expectForwardSyncExcludesFundingEntry(
            client: client, sender: sender, fundingHeight: fundingHeight, fundingTxid: fundingTxid
        )
    }
}

private extension BitcoinRegtestTests {
    /// `upperBound` excludes the funding block entirely when set below
    /// it — sender has no activity before its own first deposit.
    func expectNoHistoryBeforeFunding(
        client: BitcoinClient, sender: BitcoinDescriptor, fundingHeight: UInt64
    ) async throws {
        let historyBeforeFunding = try await client.transactionHistory(
            sender, request: BlockchainTransactionHistoryRequest(direction: .descending, upperBound: fundingHeight - 1)
        )
        #expect(historyBeforeFunding.transactions.isEmpty)
    }

    /// `lowerBound` set just past the funding block — as forward sync
    /// would after backfill established `currentHead` there — must
    /// exclude the already-synced funding entry while still surfacing
    /// the newly-mined send, or forward sync would re-read/re-save old
    /// history forever (regression guard).
    func expectForwardSyncExcludesFundingEntry(
        client: BitcoinClient, sender: BitcoinDescriptor, fundingHeight: UInt64, fundingTxid: String
    ) async throws {
        let forwardSyncHistory = try await client.transactionHistory(
            sender, request: BlockchainTransactionHistoryRequest(direction: .ascending, lowerBound: fundingHeight + 1)
        )
        #expect(!forwardSyncHistory.transactions.contains { $0.identifier == fundingTxid })
        #expect(!forwardSyncHistory.transactions.isEmpty)
    }
}
