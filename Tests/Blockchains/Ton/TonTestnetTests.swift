import BigInt
import Foundation
import Testing
@testable import WalletKit

private let environment = ProcessInfo.processInfo.environment

/// Moves Gram between two accounts of one seed on the public TON testnet, so the first send deploys the
/// recipient's wallet when it has never sent. Opt-in: needs `REEFR_TESTNET_MNEMONIC` (m/44'/607'/0' funds the
/// run, /1' receives) and optionally `TONCENTER_API_KEY`. The sender needs about 0.3 testnet GRAM from a faucet;
/// the amount sent is returned at the end, so only fees are spent.
@Suite(.serialized, .timeLimit(.minutes(5)), .enabled(if: environment["REEFR_TESTNET_MNEMONIC"] != nil))
struct TonTestnetTests {
    private static let amount = BigUInt(50_000_000)
    /// Left behind by the return leg: the recipient's compute fee plus the return transfer's own fees.
    private static let returnReserve = BigUInt(20_000_000)
    private static let minimumBalance = BigUInt(250_000_000)

    private let client = TonClient(
        network: .testnet,
        apiKey: environment["TONCENTER_API_KEY"]
    )

    private let signers: [TonPKeySigner]

    init() throws {
        let seed = try Mnemonic.fromPhrase(try #require(environment["REEFR_TESTNET_MNEMONIC"])).toSeed()
        signers = try (0..<2).map { index in
            let path = try DerivationPath(.ton(.testnet), accountIndex: UInt64(index), curve: .ed25519)
            return try TonPKeySigner(
                network: .testnet,
                privateKey: seed.masterKey(curve: .ed25519).derive(path).privateKey(),
                derivationPath: path
            )
        }
    }

    @Test func gramMovesBetweenTwoAccountsAndBack() async throws {
        let addresses = try signers.map { try $0.address() }
        let before = try await client.getNativeBalance(addresses[0])
        try #require(
            before >= Self.minimumBalance,
            "\(addresses[0].string) holds \(before) nanograms on testnet; fund it with at least \(Self.minimumBalance)."
        )

        let recipientBefore = try await client.getNativeBalance(addresses[1])
        let hash = try await send(from: 0, to: 1, amount: Self.amount)
        try await waitUntil("the recipient is credited") {
            try await client.getNativeBalance(addresses[1]) > recipientBefore
        }

        let credited = try await client.getNativeBalance(addresses[1]) - recipientBefore
        #expect(credited <= Self.amount)
        #expect(credited > Self.amount - Self.returnReserve)

        try await waitUntil("history reports the send once") {
            try await history(of: addresses[0]).contains { $0.identifier == hash && $0.status == .confirmed }
        }

        let entries = try await history(of: addresses[0]).filter { $0.identifier == hash }
        #expect(entries.count == 1)
        #expect(entries.first?.effects.first?.amount == String(Self.amount))
        #expect(try await client.accountState(addresses[1]) != .nonexistent)

        // Return the funds; the recipient's first send deploys its wallet.
        let senderBefore = try await client.getNativeBalance(addresses[0])
        _ = try await send(from: 1, to: 0, amount: credited - Self.returnReserve)
        try await waitUntil("the sender is credited") {
            try await client.getNativeBalance(addresses[0]) > senderBefore
        }

        #expect(try await client.accountState(addresses[1]) == .active)
    }

    // MARK: Helpers

    private func send(from sender: Int, to recipient: Int, amount: BigUInt) async throws -> String {
        let builder = TonTransactionBuilder(client: client, publicKey: signers[sender].account.publicKey.rawBytes)
        let transaction = try await builder.buildTransfer(
            sender: signers[sender].address(),
            recipient: signers[recipient].address(),
            amount: amount
        )

        let signature = try await signers[sender].sign(transaction: transaction)
        return try await client.broadcast(transaction: transaction, signature: signature)
    }

    private func history(of address: TonAddress) async throws -> [BlockchainTransaction] {
        try await client.transactionHistory(
            address,
            request: BlockchainTransactionHistoryRequest(direction: .descending, limit: 20)
        ).transactions
    }

    private func waitUntil(_ what: String, _ condition: () async throws -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(90))

        while ContinuousClock.now < deadline {
            if try await condition() {
                return
            }

            try await Task.sleep(for: .seconds(3))
        }

        Issue.record("Timed out waiting until \(what).")
    }
}
