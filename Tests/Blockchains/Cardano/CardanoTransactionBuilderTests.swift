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
            projectId: "project-id",
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
        #expect(transaction.outputs.contains { output in
            output.isChange && output.assets.contains { $0.quantity == "7" }
        })
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
                projectId: "project-id",
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

    /// Blockfrost's live `epochs/latest/parameters` mixes decimal strings and numbers.
    @Test func acceptsBlockfrostStringProtocolParameters() async throws {
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
          "coins_per_utxo_size":"4310",
          "key_deposit":"2000000",
          "max_tx_size":16384,
          "max_val_size":"5000",
          "min_fee_a":44,
          "min_fee_b":155381,
          "pool_deposit":"500000000"
        }
        """
        let stub = StubURLProtocol.makeSession(responsesByPath: [
            "/api/v0/accounts/\(account.stakeAddress)/utxos": .success(body: Data(utxos.utf8)),
            "/api/v0/epochs/latest/parameters": .success(body: Data(parameters.utf8))
        ])
        let builder = CardanoTransactionBuilder(client: CardanoClient(
            endpoint: URL(string: "https://cardano-preprod.blockfrost.io/api/v0")!,
            projectId: "project-id",
            session: stub.urlSession
        ))

        let envelope = try await builder.buildTransfer(
            sender: .account(account),
            recipient: .recipient(try account.address(role: 0, index: 1)),
            amount: 1_000_000,
            token: nil,
            options: []
        )

        let transaction = try JSONDecoder().decode(CardanoUnsignedTransaction.self, from: envelope)
        #expect(BigUInt(transaction.fee)! > 0)
    }

    /// Funds usually sit at later external and change addresses, not at receive address 0.
    @Test func spendsUtxosAtOtherAccountAddressesWithTheirSigningPaths() async throws {
        let account = try descriptor(network: .preprod)
        let otherEntropy = Data(repeating: 1, count: 16)
        let foreign = try CardanoAccountDescriptor(entropy: otherEntropy, network: .preprod, accountIndex: 0)
        let utxos = """
        [
          {
            "address":"\(try account.address(role: 0, index: 3).string)",
            "amount":[{"unit":"lovelace","quantity":"2000000"}],
            "output_index":0,
            "tx_hash":"\(String(repeating: "0a", count: 32))"
          },
          {
            "address":"\(try account.address(role: 1, index: 2).string)",
            "amount":[{"unit":"lovelace","quantity":"2000000"}],
            "output_index":1,
            "tx_hash":"\(String(repeating: "0b", count: 32))"
          },
          {
            "address":"\(foreign.receiveAddress.string)",
            "amount":[{"unit":"lovelace","quantity":"900000000"}],
            "output_index":0,
            "tx_hash":"\(String(repeating: "0c", count: 32))"
          }
        ]
        """
        let transactionBuilder = builder(account: account, utxos: utxos)

        // Needs both account UTxOs; the foreign one can't be signed for and must be skipped.
        let envelope = try await transactionBuilder.buildTransfer(
            sender: .account(account),
            recipient: .recipient(try account.address(role: 0, index: 1)),
            amount: 3_000_000,
            token: nil,
            options: []
        )

        let transaction = try JSONDecoder().decode(CardanoUnsignedTransaction.self, from: envelope)
        let paths = Set(transaction.signingPaths.map { "\($0.role)/\($0.index)" })

        #expect(transaction.inputs.count == 2)
        #expect(!transaction.inputs.contains { $0.txHash == Data(repeating: 0x0c, count: 32) })
        #expect(paths == ["0/3", "1/2"])
        #expect(!(try transaction.signed(entropy: entropy, accountIndex: 0)).isEmpty)
    }
}

private extension CardanoTransactionBuilderTests {
    /// A builder whose Blockfrost stub serves `utxos` and fixed protocol parameters.
    func builder(account: CardanoAccountDescriptor, utxos: String) -> CardanoTransactionBuilder {
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

        return CardanoTransactionBuilder(client: CardanoClient(
            endpoint: URL(string: "https://cardano-preprod.blockfrost.io/api/v0")!,
            projectId: "project-id",
            session: stub.urlSession
        ))
    }

    func client(network: CardanoNetwork) -> CardanoClient {
        CardanoClient(endpoint: network.rpcURL, projectId: nil)
    }

    func descriptor(network: CardanoNetwork) throws -> CardanoAccountDescriptor {
        try CardanoAccountDescriptor(entropy: entropy, network: network, accountIndex: 0)
    }
}
