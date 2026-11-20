import BigInt
import Foundation
import Testing
@testable import WalletKit

private let environment = ProcessInfo.processInfo.environment

/// Deploys the shared testnet Jetton fixture (see ``TonJettonFixture``) and writes its master address to a temp file. Opt-in:
/// needs `REEFR_TESTNET_MNEMONIC`; account 0 needs about 0.3 testnet GRAM the first time.
@Suite(.serialized, .timeLimit(.minutes(3)), .enabled(if: environment["REEFR_TESTNET_MNEMONIC"] != nil))
struct TonJettonFixtureTests {
    @Test func theFixtureIsDeployedWithItsSupplyMintedToTheAdmin() async throws {
        let seed = try Mnemonic.fromPhrase(try #require(environment["REEFR_TESTNET_MNEMONIC"])).toSeed()
        let path = try DerivationPath(.ton(.testnet), accountIndex: 0, curve: .ed25519)
        let admin = try TonPKeySigner(
            network: .testnet,
            privateKey: seed.masterKey(curve: .ed25519).derive(path).privateKey(),
            derivationPath: path
        )

        let client = TonClient(network: .testnet, apiKey: environment["TONCENTER_API_KEY"])
        let fixture = TonJettonFixture(client: client, admin: admin)
        try await fixture.ensureDeployed()

        // Where to read the address from when running the test by hand.
        let file = FileManager.default.temporaryDirectory.appending(path: "ton-jetton-fixture-master.txt")
        try fixture.minter.string.write(to: file, atomically: true, encoding: .utf8)
        #expect(try await fixture.client.accountState(fixture.minter) == .active)
    }

    @Test func jettonsMoveToAnOwnerWithoutAWalletAndAnOverspendFailsDownstream() async throws {
        let seed = try Mnemonic.fromPhrase(try #require(environment["REEFR_TESTNET_MNEMONIC"])).toSeed()
        let path = try DerivationPath(.ton(.testnet), accountIndex: 0, curve: .ed25519)
        let admin = try TonPKeySigner(
            network: .testnet,
            privateKey: seed.masterKey(curve: .ed25519).derive(path).privateKey(),
            derivationPath: path
        )

        let otherPath = try DerivationPath(.ton(.testnet), accountIndex: 2, curve: .ed25519)
        let recipient = try TonPKeySigner(
            network: .testnet,
            privateKey: seed.masterKey(curve: .ed25519).derive(otherPath).privateKey(),
            derivationPath: otherPath
        ).address()

        let client = TonClient(network: .testnet, apiKey: environment["TONCENTER_API_KEY"])
        let fixture = TonJettonFixture(client: client, admin: admin)
        try await fixture.ensureDeployed()
        let master = try fixture.minter

        // Round 1: 1.5 tokens to an owner that has no Jetton wallet yet.
        let before = try await client.jettonBalance(owner: admin.address(), master: master)
        let receivedBefore = try await client.jettonBalance(owner: recipient, master: master)
        let ok = try await fixture.transfer(amount: 1_500_000, to: recipient, attached: 50_000_000)
        try await Task.sleep(for: .seconds(45))

        // Round 2: more than the balance, which the sender's Jetton wallet refuses.
        let bad = try await fixture.transfer(amount: before * 10, to: recipient, attached: 50_000_000)
        try await Task.sleep(for: .seconds(45))

        let file = FileManager.default.temporaryDirectory.appending(path: "ton-jetton-fixture-sends.txt")
        try "ok=\(ok)\nbad=\(bad)\nrecipient=\(recipient.string)\nmaster=\(master.string)\n"
            .write(to: file, atomically: true, encoding: .utf8)

        let received = try await client.jettonBalance(owner: recipient, master: master)
        #expect(received - receivedBefore == 1_500_000)
        #expect(try await client.jettonBalance(owner: admin.address(), master: master) == before - 1_500_000)
    }

    @Test func theBuilderSendsJettonsThroughTheSendersJettonWallet() async throws {
        let seed = try Mnemonic.fromPhrase(try #require(environment["REEFR_TESTNET_MNEMONIC"])).toSeed()
        let path = try DerivationPath(.ton(.testnet), accountIndex: 0, curve: .ed25519)
        let key = try seed.masterKey(curve: .ed25519).derive(path).privateKey()
        let admin = try TonPKeySigner(network: .testnet, privateKey: key, derivationPath: path)
        let client = TonClient(network: .testnet, apiKey: environment["TONCENTER_API_KEY"])
        let fixture = TonJettonFixture(client: client, admin: admin)
        try await fixture.ensureDeployed()
        let master = try fixture.minter

        let recipientPath = try DerivationPath(.ton(.testnet), accountIndex: 1, curve: .ed25519)
        let recipient = try TonPKeySigner(
            network: .testnet,
            privateKey: seed.masterKey(curve: .ed25519).derive(recipientPath).privateKey(),
            derivationPath: recipientPath
        ).address()

        let before = try await client.getBalance(recipient, token: master.string)
        let builder = TonTransactionBuilder(client: client, publicKey: key.publicKey.rawBytes)
        let data = try await builder.buildTransfer(
            sender: admin.address(),
            recipient: recipient,
            amount: 250_000,
            token: master.string,
            options: []
        )

        let request = try JSONDecoder().decode(TonUnsignedTransaction.self, from: data)
        #expect(request.jetton?.amount == "250000")
        #expect(request.value == String(TonTransactionBuilder.defaultJettonAttachment))

        let signature = try await admin.sign(transaction: data)
        _ = try await client.broadcast(transaction: data, signature: signature)

        let deadline = ContinuousClock.now.advanced(by: .seconds(90))
        var after = before

        while after == before, ContinuousClock.now < deadline {
            try await Task.sleep(for: .seconds(3))
            after = try await client.getBalance(recipient, token: master.string)
        }

        #expect(after - before == 250_000)
        #expect(try await client.getAllBalances(recipient)[master.string] == after)
        #expect(try await client.getTokenInfo(master.string).decimals == 6)
        #expect(try await client.getTokenInfo(master.string).symbol == "RTJ")
    }
}
