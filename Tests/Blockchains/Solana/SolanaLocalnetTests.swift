// Integration test for SolanaRPCClient/SolanaTransactionBuilder/
// SolanaPKeySigner against a real, running local `solana-test-validator`
// (see SolanaNode.swift) — derives a wallet, airdrops it native SOL,
// signs and broadcasts a real transfer, and confirms the chain's own
// balance changed by exactly the expected amount. Also exercises the SPL
// path end to end (mint via the bundled `spl-token` CLI, transfer to a
// recipient with no existing associated token account, confirming the
// builder's `CreateIdempotent` prepend actually creates it) and account
// history. Mirrors `SuiLocalnetTests`' "real infrastructure, not a mock"
// philosophy.
//
// No `withKnownIssue` gating: if `make solana-testing` hasn't been run,
// or the validator never becomes healthy, this fails loudly rather than
// skipping quietly — the same choice `SuiLocalnetTests`/
// `EthereumAnvilTests` make for their own local nodes.

import BigInt
import Foundation
import Testing
import WalletKit
import WalletKitTesting

private func makeSigner(network: SolanaNetwork = .devnet) throws -> SolanaPKeySigner {
    let seed = Mnemonic.generate().toSeed()
    let path = TestAccountFactory.slip10Path(coinType: 501)
    let privateKey = try seed.masterKey(curve: .ed25519).derive(path).privateKey()
    return try SolanaPKeySigner(network: network, privateKey: privateKey, derivationPath: path)
}

/// Builds, signs, and broadcasts a transfer via the same three-step
/// path `TransactionService` drives in the app, then waits for the
/// signature to confirm.
///
/// - Returns: The broadcast signature.
private func send(
    client: SolanaRPCClient,
    builder: SolanaTransactionBuilder,
    node: SolanaNode,
    signer: SolanaPKeySigner,
    recipient: SolanaAddress,
    amount: BigUInt,
    token: String?
) async throws -> String {
    let sender = try signer.address()
    let unsigned = try await builder.buildTransfer(sender: sender, recipient: recipient, amount: amount, token: token)
    let signature = try await signer.sign(transaction: unsigned)
    let txid = try await client.broadcast(transaction: unsigned, signature: signature)
    try await node.waitForConfirmation(signature: txid)
    return txid
}

// `.serialized`: each test spins up its own full local validator process
// — see `SuiLocalnetTests`' identical note on why concurrent instances
// blow past a tight per-test time limit.
@Suite(.timeLimit(.minutes(2)), .serialized)
struct SolanaLocalnetTests {
    @Test func estimateFeeRatesOnlyReturnsARecentPriorityFee() async throws {
        let node = try await SolanaNode.start()
        defer { node.stop() }

        let client = SolanaRPCClient(endpoint: node.rpcURL)
        let estimate = try await client.estimateFee(for: nil)
        #expect(estimate.gasLimit == nil)
        #expect(estimate.estimatedFee == nil)
    }

    @Test func nativeTransferMovesExactlyTheRequestedLamportsPlusFee() async throws {
        let node = try await SolanaNode.start()
        defer { node.stop() }

        let client = SolanaRPCClient(endpoint: node.rpcURL)
        let builder = SolanaTransactionBuilder(client: client)

        let sender = try makeSigner()
        let senderAddress = try sender.address()
        let recipient = try makeSigner().address()

        _ = try await node.airdrop(to: senderAddress, lamports: 1_000_000_000)

        let recipientBalanceBefore = try await client.getNativeBalance(recipient)
        let senderBalanceBefore = try await client.getNativeBalance(senderAddress)

        let transferAmount = BigUInt(10_000_000)
        _ = try await send(
            client: client, builder: builder, node: node, signer: sender,
            recipient: recipient, amount: transferAmount, token: nil
        )

        let recipientBalanceAfter = try await client.getNativeBalance(recipient)
        let senderBalanceAfter = try await client.getNativeBalance(senderAddress)

        #expect(recipientBalanceAfter - recipientBalanceBefore == transferAmount)
        #expect(senderBalanceBefore - senderBalanceAfter > transferAmount) // covers the network fee too
    }

    @Test func transactionHistoryIncludesABroadcastTransfer() async throws {
        let node = try await SolanaNode.start()
        defer { node.stop() }

        let client = SolanaRPCClient(endpoint: node.rpcURL)
        let builder = SolanaTransactionBuilder(client: client)

        let sender = try makeSigner()
        let senderAddress = try sender.address()
        let recipient = try makeSigner().address()
        _ = try await node.airdrop(to: senderAddress, lamports: 1_000_000_000)

        let signature = try await send(
            client: client, builder: builder, node: node, signer: sender,
            recipient: recipient, amount: BigUInt(5_000_000), token: nil
        )

        let page = try await client.transactionHistory(
            senderAddress,
            request: BlockchainTransactionHistoryRequest(direction: .descending, limit: 10)
        )
        #expect(page.transactions.contains { $0.identifier == signature })
    }

    @Test func transactionHistoryIncludesACreditToAnExistingTokenAccount() async throws {
        let node = try await SolanaNode.start()
        defer { node.stop() }

        let client = SolanaRPCClient(endpoint: node.rpcURL)
        let owner = try makeSigner().address()

        // `spl-token mint`'s credit lands in `owner`'s already-created
        // associated token account without naming `owner` itself among the
        // transaction's account keys — the same shape as any incoming SPL
        // transfer into an account that already exists, and a transaction
        // `getSignaturesForAddress` never reports for `owner`.
        let mintedAmount: UInt64 = 1_000_000
        let mint = try await node.mintSPLToken(decimals: 6, to: owner, amount: mintedAmount)

        let page = try await client.transactionHistory(
            owner,
            request: BlockchainTransactionHistoryRequest(direction: .descending, limit: 10)
        )

        #expect(page.transactions.contains { transaction in
            transaction.effects.contains {
                $0.kind == .tokenTransfer && $0.assetIdentifier == mint.string && $0.amount == "\(mintedAmount)"
            }
        })
    }

    @Test func splTransferCreatesTheRecipientsAssociatedTokenAccount() async throws {
        let node = try await SolanaNode.start()
        defer { node.stop() }

        let client = SolanaRPCClient(endpoint: node.rpcURL)
        let builder = SolanaTransactionBuilder(client: client)

        let sender = try makeSigner()
        let senderAddress = try sender.address()
        let recipient = try makeSigner().address()
        _ = try await node.airdrop(to: senderAddress, lamports: 1_000_000_000)

        let decimals: UInt8 = 6
        let mintedAmount: UInt64 = 1_000_000
        let mint = try await node.mintSPLToken(decimals: decimals, to: senderAddress, amount: mintedAmount)

        // No account exists yet at the recipient's ATA — this is the
        // precondition the builder's unconditional `CreateIdempotent`
        // prepend is supposed to satisfy without a prior existence check.
        let recipientBalanceBefore = try await client.getBalance(recipient, token: mint.string)
        #expect(recipientBalanceBefore == 0)

        let transferAmount = BigUInt(250_000)
        _ = try await send(
            client: client, builder: builder, node: node, signer: sender,
            recipient: recipient, amount: transferAmount, token: mint.string
        )

        let recipientBalance = try await client.getBalance(recipient, token: mint.string)
        #expect(recipientBalance == transferAmount)

        let senderBalance = try await client.getBalance(senderAddress, token: mint.string)
        #expect(senderBalance == BigUInt(mintedAmount) - transferAmount)
    }
}
