// End-to-end against `aptos node run-localnet` (AptosNode): derive, fund,
// build, sign, broadcast, and check exact balances, for both curves and all
// three transfer entry functions. Indexer-backed history is covered by
// AptosClientTests (the localnet indexer needs Docker).

import BigInt
import Foundation
import Testing
@testable import WalletKit
import WalletKitTesting

private let fundedOctas: UInt64 = 100_000_000

private func makeSigner(curve: Curve, seed: UInt8) throws -> AptosPKeySigner {
    let privateKey = try PrivateKey(curve: curve, rawBytes: Data(repeating: seed, count: 32))
    return try AptosPKeySigner(
        curve: curve,
        network: .testnet,
        privateKey: privateKey,
        derivationPath: DerivationPath(.aptos(.testnet), accountIndex: 0, curve: curve)
    )
}

/// Signs and broadcasts `transaction`, waits for it to commit, and returns
/// the fee it was charged.
private func send(_ transaction: Data, signer: AptosPKeySigner, node: AptosNode) async throws -> UInt64 {
    let signature = try await signer.sign(transaction: transaction)
    let hash = try await node.client().broadcast(transaction: transaction, signature: signature)
    #expect(hash == AptosClient.transactionHash(of: transaction + signature))

    let status = try await node.waitForCommit(hash)
    return try #require(status.fee)
}

// Each test runs its own localnet; `.serialized` keeps one starting at a time.
@Suite(.timeLimit(.minutes(3)), .serialized, .localNode)
struct AptosLocalnetTests {
    @Test(.serialized, arguments: [Curve.ed25519, .secp256k1])
    func nativeTransferMovesExactBalances(curve: Curve) async throws {
        let node = try await AptosNode.start()
        defer { node.stop() }

        let client = node.client()
        let signer = try makeSigner(curve: curve, seed: 0x31)
        let sender = try signer.address()
        let recipient = try makeSigner(curve: .ed25519, seed: 0x32).address()

        #expect(try await client.isActiveAccount(sender) == false)
        try await node.fund(sender, octas: fundedOctas)
        #expect(try await client.isActiveAccount(sender))

        let amount: UInt64 = 12_345
        let transaction = try await AptosTransactionBuilder(client: client)
            .buildTransfer(sender: sender, recipient: recipient, amount: BigUInt(amount))
        let fee = try await send(transaction, signer: signer, node: node)

        #expect(try await client.getNativeBalance(sender) == BigUInt(fundedOctas - amount - fee))
        #expect(try await client.getNativeBalance(recipient) == BigUInt(amount))
        #expect(try await client.sequenceNumber(of: sender) == 1)
    }

    @Test func coinAndFungibleAssetEntryFunctionsMoveApt() async throws {
        let node = try await AptosNode.start()
        defer { node.stop() }

        let client = node.client()
        let signer = try makeSigner(curve: .ed25519, seed: 0x41)
        let sender = try signer.address()
        let recipient = try makeSigner(curve: .secp256k1, seed: 0x42).address()
        try await node.fund(sender, octas: fundedOctas)

        let payloads: [AptosEntryFunction] = [
            .coinTransfer(coinType: try MoveType(parsing: AptosClient.nativeCoinType), to: recipient, amount: 7),
            .fungibleAssetTransfer(metadata: try AptosAddress(string: "0xa"), to: recipient, amount: 9)
        ]
        var fees: UInt64 = 0

        for (sequenceNumber, payload) in payloads.enumerated() {
            let ledger = try await client.ledgerInfo()
            let transaction = AptosRawTransaction(
                sender: sender,
                sequenceNumber: UInt64(sequenceNumber),
                payload: payload,
                maxGasAmount: 20_000,
                gasUnitPrice: try await client.estimateGasPrice().estimate,
                expirationTimestampSecs: ledger.ledgerTimestamp / 1_000_000 + 600,
                chainId: ledger.chainId
            )
            fees += try await send(transaction.bcs, signer: signer, node: node)
        }

        #expect(try await client.getNativeBalance(recipient) == 16)
        #expect(try await client.getBalance(recipient, token: "0xa") == 16)
        #expect(try await client.getNativeBalance(sender) == BigUInt(fundedOctas - 16 - fees))
    }

    @Test func builderRejectsAnUnfundedSender() async throws {
        let node = try await AptosNode.start()
        defer { node.stop() }

        let sender = try makeSigner(curve: .ed25519, seed: 0x51).address()
        let recipient = try makeSigner(curve: .ed25519, seed: 0x52).address()

        await #expect(throws: BlockchainTransactionBuilderError.self) {
            _ = try await AptosTransactionBuilder(client: node.client())
                .buildTransfer(sender: sender, recipient: recipient, amount: 1)
        }
    }

    @Test func gasOverrideIsHonoured() async throws {
        let node = try await AptosNode.start()
        defer { node.stop() }

        let client = node.client()
        let signer = try makeSigner(curve: .secp256k1, seed: 0x61)
        let sender = try signer.address()
        try await node.fund(sender, octas: fundedOctas)

        let transaction = try await AptosTransactionBuilder(client: client).buildTransfer(
            sender: sender,
            recipient: sender,
            amount: 1,
            token: nil,
            options: [.aptosGasOverride(maxGasAmount: 30_000, gasUnitPrice: 150)]
        )
        let fee = try await send(transaction, signer: signer, node: node)

        #expect(fee.isMultiple(of: 150))
        #expect(try await client.getNativeBalance(sender) == BigUInt(fundedOctas - fee))
    }
}
