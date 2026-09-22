import Foundation
import Testing
@testable import WalletKit

struct CardanoClientTests {
    private let endpoint = URL(string: "https://cardano-preprod.blockfrost.io/api/v0")!
    private let entropy = Data(repeating: 0, count: 16)

    @Test func nativeBalanceSumsTheAccountsLovelaceUtxos() async throws {
        let owner = try descriptor()
        let response = """
        [{
          "address":"\(owner.receiveAddress.string)",
          "amount":[{"unit":"lovelace","quantity":"1234567"}],
          "output_index":0,
          "tx_hash":"\(String(repeating: "07", count: 32))"
        }]
        """
        let stub = StubURLProtocol.makeSession(response: .success(body: Data(response.utf8)))
        let client = CardanoClient(endpoint: endpoint, projectID: "project-id", session: stub.urlSession)

        #expect(try await client.getNativeBalance(owner) == 1_234_567)
        #expect(stub.capturedRequest?.url?.path == "/api/v0/accounts/\(owner.stakeAddress)/utxos")
        #expect(stub.capturedRequest?.value(forHTTPHeaderField: "project_id") == "project-id")
    }

    @Test func emptyUtxosAreAnInactiveAccount() async throws {
        let stub = StubURLProtocol.makeSession(response: .success(body: Data("[]".utf8)))
        let client = CardanoClient(endpoint: endpoint, projectID: "project-id", session: stub.urlSession)

        #expect(!(try await client.isActiveAccount(descriptor())))
    }

    @Test func allBalancesIncludeNativeAssets() async throws {
        let owner = try descriptor()
        let response = """
        [{
          "address":"\(owner.receiveAddress.string)",
          "amount":[
            {"unit":"lovelace","quantity":"1234567"},
            {"unit":"asset-policy-token","quantity":"42"}
          ],
          "output_index":0,
          "tx_hash":"\(String(repeating: "07", count: 32))"
        }]
        """
        let stub = StubURLProtocol.makeSession(response: .success(body: Data(response.utf8)))
        let client = CardanoClient(endpoint: endpoint, projectID: "project-id", session: stub.urlSession)

        let balances = try await client.getAllBalances(owner)

        #expect(balances["lovelace"] == 1_234_567)
        #expect(balances["asset-policy-token"] == 42)
    }

    @Test func assetMetadataBecomesTokenInfo() async throws {
        let response = """
        {"onchain_metadata":{"decimals":6,"name":"Test Token","ticker":"TST"}}
        """
        let stub = StubURLProtocol.makeSession(response: .success(body: Data(response.utf8)))
        let client = CardanoClient(endpoint: endpoint, projectID: "project-id", session: stub.urlSession)

        let token = try await client.getTokenInfo("asset-policy-token")

        #expect(token.decimals == 6)
        #expect(token.name == "Test Token")
        #expect(token.symbol == "TST")
        #expect(!token.isNative)
    }

    @Test func broadcastPostsTheSignedCborAndReturnsTheTransactionID() async throws {
        let stub = StubURLProtocol.makeSession(response: .success(body: Data("submitted-tx-id\n".utf8)))
        let client = CardanoClient(endpoint: endpoint, projectID: "project-id", session: stub.urlSession)

        #expect(try await client.broadcast(transaction: Data(), signature: Data([0xde, 0xad])) == "submitted-tx-id")
        #expect(stub.capturedRequest?.url?.path == "/api/v0/tx/submit")
        #expect(stub.capturedRequest?.httpMethod == "POST")
        #expect(stub.capturedRequest?.value(forHTTPHeaderField: "Content-Type") == "application/cbor")
        #expect(stub.capturedBody == Data([0xde, 0xad]))
    }

    @Test func transactionHistoryMapsBlockfrostTransactions() async throws {
        let response = """
        [{
          "block":"block-hash",
          "block_height":123,
          "block_time":456,
          "tx_hash":"transaction-hash"
        }]
        """
        let stub = StubURLProtocol.makeSession(response: .success(body: Data(response.utf8)))
        let client = CardanoClient(endpoint: endpoint, projectID: "project-id", session: stub.urlSession)

        let page = try await client.transactionHistory(
            descriptor(),
            request: BlockchainTransactionHistoryRequest(direction: .descending, limit: 10)
        )

        #expect(page.transactions.map(\.identifier) == ["transaction-hash"])
        #expect(page.transactions.first?.blockHeight == 123)
        #expect(page.transactions.first?.timestamp == Date(timeIntervalSince1970: 456))
        #expect(page.reachedBoundary)
    }
}

private extension CardanoClientTests {
    func descriptor() throws -> CardanoAccountDescriptor {
        try CardanoAccountDescriptor(entropy: entropy, network: .preprod, accountIndex: 0)
    }
}
