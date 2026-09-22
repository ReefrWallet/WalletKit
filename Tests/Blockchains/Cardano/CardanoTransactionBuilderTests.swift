import BigInt
import Foundation
import Testing
@testable import WalletKit

struct CardanoTransactionBuilderTests {
    private let entropy = Data(repeating: 0, count: 16)

    @Test func buildsANativeAssetTransferAndPreservesChangeAssets() async throws {
        let account = try descriptor(network: .preprod)
        let policy = String(repeating: "09", count: 28)
        let utxos = """
        [{
          "address":"\(account.receiveAddress.string)",
          "amount":[
            {"unit":"lovelace","quantity":"5000000"},
            {"unit":"\(policy)54455354","quantity":"10"}
          ],
          "output_index":0,
          "tx_hash":"\(String(repeating: "08", count: 32))"
        }]
        """
        let parameters = """
        {
          "coins_per_utxo_size":4310,
          "key_deposit":2000000,
          "max_tx_size":16384,
          "max_val_size":5000,
          "min_fee_a":44,
          "min_fee_b":155381,
          "pool_deposit":500000000
        }
        """
        let stub = StubURLProtocol.makeSession(responsesByPath: [
            "/api/v0/accounts/\(account.stakeAddress)/utxos": .success(body: Data(utxos.utf8)),
            "/api/v0/epochs/latest/parameters": .success(body: Data(parameters.utf8))
        ])
        let builder = CardanoTransactionBuilder(client: CardanoClient(
            endpoint: URL(string: "https://cardano-preprod.blockfrost.io/api/v0")!,
            projectID: "project-id",
            session: stub.urlSession
        ))
        let envelope = try await builder.buildTransfer(
            sender: .account(account),
            recipient: .recipient(try account.address(role: 0, index: 1)),
            amount: 3,
            token: "\(policy)54455354",
            options: [.cardanoRecipientLovelace(2_000_000)]
        )
        let transaction = try JSONDecoder().decode(CardanoUnsignedTransaction.self, from: envelope)

        #expect(transaction.outputs.contains { output in output.assets.contains { $0.quantity == "3" } })
        #expect(transaction.outputs.contains { output in output.isChange && output.assets.contains { $0.quantity == "7" } })
    }

    @Test func rejectsARecipientFromAnotherNetworkBeforeRequestingUtxos() async throws {
        let account = try descriptor(network: .preprod)
        let recipient = try descriptor(network: .mainnet).receiveAddress
        let builder = CardanoTransactionBuilder(client: client(network: .preprod))

        await #expect(throws: WalletKitError.self) {
            _ = try await builder.buildTransfer(
                sender: .account(account),
                recipient: .recipient(recipient),
                amount: 1,
                token: nil,
                options: []
            )
        }
    }

    @Test func buildsAnUnsignedAdaTransactionFromBlockfrostUtxos() async throws {
        let account = try descriptor(network: .preprod)
        let utxos = """
        [{
          "address":"\(account.receiveAddress.string)",
          "amount":[{"unit":"lovelace","quantity":"5000000"}],
          "output_index":0,
          "tx_hash":"\(String(repeating: "07", count: 32))"
        }]
        """
        let parameters = """
        {
          "coins_per_utxo_size":4310,
          "key_deposit":2000000,
          "max_tx_size":16384,
          "max_val_size":5000,
          "min_fee_a":44,
          "min_fee_b":155381,
          "pool_deposit":500000000
        }
        """
        let stub = StubURLProtocol.makeSession(responsesByPath: [
            "/api/v0/accounts/\(account.stakeAddress)/utxos": .success(body: Data(utxos.utf8)),
            "/api/v0/epochs/latest/parameters": .success(body: Data(parameters.utf8))
        ])
        let builder = CardanoTransactionBuilder(
            client: CardanoClient(
                endpoint: URL(string: "https://cardano-preprod.blockfrost.io/api/v0")!,
                projectID: "project-id",
                session: stub.urlSession
            )
        )

        let envelope = try await builder.buildTransfer(
            sender: .account(account),
            recipient: .recipient(try account.address(role: 0, index: 1)),
            amount: 1_000_000,
            token: nil,
            options: []
        )
        let transaction = try JSONDecoder().decode(CardanoUnsignedTransaction.self, from: envelope)
        let signed = try transaction.signed(entropy: entropy, accountIndex: 0)

        #expect(!transaction.transactionBody.isEmpty)
        #expect(!signed.isEmpty)
        #expect(BigUInt(transaction.fee)! > 0)
        #expect(transaction.signingPaths.count == 1)
        #expect(transaction.signingPaths.first?.role == 0)
        #expect(transaction.signingPaths.first?.index == 0)
    }
}

private extension CardanoTransactionBuilderTests {
    func client(network: CardanoNetwork) -> CardanoClient {
        CardanoClient(endpoint: network.rpcURL, projectID: nil)
    }

    func descriptor(network: CardanoNetwork) throws -> CardanoAccountDescriptor {
        try CardanoAccountDescriptor(entropy: entropy, network: network, accountIndex: 0)
    }
}
