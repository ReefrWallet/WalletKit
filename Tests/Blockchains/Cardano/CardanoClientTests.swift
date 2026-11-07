import Foundation
import Testing
import WalletKitRust
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
        let client = CardanoClient(endpoint: endpoint, projectId: "project-id", session: stub.urlSession)

        #expect(try await client.getNativeBalance(owner) == 1_234_567)
        #expect(stub.capturedRequest?.url?.path == "/api/v0/accounts/\(owner.stakeAddress)/utxos")
        #expect(stub.capturedRequest?.value(forHTTPHeaderField: "project_id") == "project-id")
    }

    @Test func emptyUtxosAreAnInactiveAccount() async throws {
        let stub = StubURLProtocol.makeSession(response: .success(body: Data("[]".utf8)))
        let client = CardanoClient(endpoint: endpoint, projectId: "project-id", session: stub.urlSession)

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
        let client = CardanoClient(endpoint: endpoint, projectId: "project-id", session: stub.urlSession)

        let balances = try await client.getAllBalances(owner)

        #expect(balances["lovelace"] == 1_234_567)
        #expect(balances["asset-policy-token"] == 42)
    }

    @Test func assetMetadataBecomesTokenInfo() async throws {
        let response = """
        {"onchain_metadata":{"decimals":6,"name":"Test Token","ticker":"TST"}}
        """
        let stub = StubURLProtocol.makeSession(response: .success(body: Data(response.utf8)))
        let client = CardanoClient(endpoint: endpoint, projectId: "project-id", session: stub.urlSession)

        let token = try await client.getTokenInfo("asset-policy-token")

        #expect(token.decimals == 6)
        #expect(token.name == "Test Token")
        #expect(token.symbol == "TST")
        #expect(!token.isNative)
    }

    @Test func broadcastPostsTheSignedCborAndReturnsTheTransactionID() async throws {
        let stub = StubURLProtocol.makeSession(response: .success(body: Data("submitted-tx-id\n".utf8)))
        let client = CardanoClient(endpoint: endpoint, projectId: "project-id", session: stub.urlSession)

        #expect(try await client.broadcast(transaction: Data(), signature: Data([0xde, 0xad])) == "submitted-tx-id")
        #expect(stub.capturedRequest?.url?.path == "/api/v0/tx/submit")
        #expect(stub.capturedRequest?.httpMethod == "POST")
        #expect(stub.capturedRequest?.value(forHTTPHeaderField: "Content-Type") == "application/cbor")
        #expect(stub.capturedBody == Data([0xde, 0xad]))
    }

    /// Covers the ambiguous-retry case: a 429/503 retry can land on an
    /// already-submitted-shaped rejection even though the first attempt
    /// landed. The canonical tx hash is the *unsigned* body's hash (not a
    /// hash of the complete signed CBOR, which also includes the witness
    /// set), so it's recovered locally from the envelope
    /// `CardanoTransactionBuilder` already produced, instead of trusting a
    /// possibly-inconsistent second response.
    @Test func broadcastRecoversTheTxHashLocallyWhenAlreadySubmitted() async throws {
        let account = try descriptor()
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
        let buildStub = StubURLProtocol.makeSession(responsesByPath: [
            "/api/v0/accounts/\(account.stakeAddress)/utxos": .success(body: Data(utxos.utf8)),
            "/api/v0/epochs/latest/parameters": .success(body: Data(parameters.utf8))
        ])
        let builder = CardanoTransactionBuilder(client: CardanoClient(
            endpoint: endpoint,
            projectId: "project-id",
            session: buildStub.urlSession
        ))

        let envelope = try await builder.buildTransfer(
            sender: .account(account),
            recipient: .recipient(try account.address(role: 0, index: 1)),
            amount: 1_000_000,
            token: nil,
            options: []
        )

        let unsigned = try JSONDecoder().decode(CardanoUnsignedTransaction.self, from: envelope)
        let expectedHash = try unsigned.transactionBodyHash().map { String(format: "%02x", $0) }.joined()

        let submitStub = StubURLProtocol.makeSession(
            response: .success(statusCode: 400, body: Data("Transaction already submitted".utf8))
        )

        let client = CardanoClient(endpoint: endpoint, projectId: "project-id", session: submitStub.urlSession)

        let result = try await client.broadcast(transaction: envelope, signature: Data([0xde, 0xad]))
        #expect(result == expectedHash)
    }

    /// Blockfrost answers a submit with the hash as a JSON string, quotes included.
    @Test func broadcastReturnsTheHashWithoutItsJSONQuotes() async throws {
        let stub = StubURLProtocol.makeSession(response: .success(body: Data("\"abc123\"\n".utf8)))
        let client = CardanoClient(endpoint: endpoint, projectId: "project-id", session: stub.urlSession)

        #expect(try await client.broadcast(transaction: Data(), signature: Data([1])) == "abc123")
    }

    private static let spentInputs = "All inputs are spent. Transaction has probably already been included"

    private struct SpentInputs {
        let client: CardanoClient
        let envelope: Data
        let hash: String
    }

    /// A transaction spending output 0 of a fixed producer, with Blockfrost's answers to the lookups
    /// a spent-inputs rejection triggers. `consumedBy` is the producer output's `consumed_by_tx`.
    private func spentInputsFixture(
        landed: Bool,
        consumedBy: String? = nil,
        lookup: StubURLProtocol.StubResponse? = nil
    ) throws -> SpentInputs {
        let producer = Data(repeating: 7, count: 32)
        let unsigned = CardanoUnsignedTransaction(
            fee: "170000",
            inputs: [CardanoTransactionInputFfi(outputIndex: 0, txHash: producer)],
            networkId: 0,
            outputs: [],
            signingPaths: [],
            staking: nil,
            transactionBody: Data([0xA3, 0x00, 0x80, 0x01, 0x80, 0x02, 0x00]),
            ttl: 1
        )

        let hash = try unsigned.transactionBodyHash().map { String(format: "%02x", $0) }.joined()
        let consumer = consumedBy.map { "\"\($0)\"" } ?? "null"
        let stub = StubURLProtocol.makeSession(responsesByPath: [
            "/api/v0/tx/submit": .success(statusCode: 400, body: Data(Self.spentInputs.utf8)),
            "/api/v0/txs/\(hash)": lookup ?? (landed
                ? .success(body: Data(#"{"hash":"\#(hash)"}"#.utf8))
                : .success(statusCode: 404, body: Data("{}".utf8))),
            "/api/v0/txs/\(String(repeating: "07", count: 32))/utxos":
                .success(body: Data(#"{"outputs":[{"output_index":0,"consumed_by_tx":\#(consumer)}]}"#.utf8))
        ])

        return SpentInputs(
            client: CardanoClient(endpoint: endpoint, projectId: "project-id", session: stub.urlSession),
            envelope: try JSONEncoder().encode(unsigned),
            hash: hash
        )
    }

    /// A retry of a transaction that already landed finds its inputs spent.
    @Test func spentInputsAreSuccessOnlyWhenTheTransactionIsOnChain() async throws {
        let fixture = try spentInputsFixture(landed: true)

        #expect(try await fixture.client.broadcast(transaction: fixture.envelope, signature: Data([1])) == fixture.hash)
    }

    /// A failed lookup says nothing: it is thrown so the submission stays tracked, not read as a rejection.
    @Test func aFailedLookupIsNotReadAsARejection() async throws {
        let fixture = try spentInputsFixture(landed: false, lookup: .success(statusCode: 500, body: Data("{}".utf8)))

        do {
            _ = try await fixture.client.broadcast(transaction: fixture.envelope, signature: Data([1]))
            Issue.record("expected a throw")
        } catch let WalletKitError.internalError(message) {
            #expect(!message.contains("probably already been included"))
        }
    }

    /// An input another transaction consumed makes it a rejection: the caller rebuilds.
    @Test func spentInputsAreARejectionOnceAnotherTransactionIsSeenConsumingThem() async throws {
        let fixture = try spentInputsFixture(landed: false, consumedBy: String(repeating: "ab", count: 32))

        do {
            _ = try await fixture.client.broadcast(transaction: fixture.envelope, signature: Data([1]))
            Issue.record("expected a throw")
        } catch let WalletKitError.internalError(message) {
            #expect(message.contains("probably already been included"))
        }
    }

    /// Before the index shows the transaction or a consumer, the first attempt may still confirm.
    @Test func spentInputsStayUnresolvedUntilTheIndexCatchesUp() async throws {
        let fixture = try spentInputsFixture(landed: false)

        do {
            _ = try await fixture.client.broadcast(transaction: fixture.envelope, signature: Data([1]))
            Issue.record("expected a throw")
        } catch let WalletKitError.internalError(message) {
            #expect(message.contains("unresolved"))
            #expect(!message.contains("status_code"))
        }
    }

    /// A dapp resubmitting a confirmed transaction still gets its hash back.
    @Test func aDappResubmissionOfAConfirmedTransactionReturnsItsHash() async throws {
        let raw = Data([0x84, 0xA3, 0x00, 0x80, 0x01, 0x80, 0x02, 0x00, 0xA0, 0xF5, 0xF6])
        let hash = try cardanoTransactionHash(transaction: raw).map { String(format: "%02x", $0) }.joined()
        let stub = StubURLProtocol.makeSession(responsesByPath: [
            "/api/v0/tx/submit": .success(statusCode: 400, body: Data(Self.spentInputs.utf8)),
            "/api/v0/txs/\(hash)": .success(body: Data(#"{"hash":"\#(hash)"}"#.utf8))
        ])
        let client = CardanoClient(endpoint: endpoint, projectId: "project-id", session: stub.urlSession)

        #expect(try await client.submit(rawTransaction: raw) == hash)
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
        let client = CardanoClient(endpoint: endpoint, projectId: "project-id", session: stub.urlSession)

        let page = try await client.transactionHistory(
            descriptor(),
            request: BlockchainTransactionHistoryRequest(direction: .descending, limit: 10)
        )

        #expect(page.transactions.map(\.identifier) == ["transaction-hash"])
        #expect(page.transactions.first?.blockHeight == 123)
        #expect(page.transactions.first?.timestamp == Date(timeIntervalSince1970: 456))
        #expect(page.reachedBoundary)
        // Forward sync never starts polling without a head.
        #expect(page.head == 123)
    }

    @Test func transactionHistoryFallsBackToTheChainTipForAHeadlessPage() async throws {
        let owner = try descriptor()
        let stub = StubURLProtocol.makeSession(responsesByPath: [
            "/api/v0/accounts/\(owner.stakeAddress)/transactions": .success(body: Data("[]".utf8)),
            "/api/v0/blocks/latest": .success(body: Data(#"{"height":9876}"#.utf8))
        ])
        let client = CardanoClient(endpoint: endpoint, projectId: "project-id", session: stub.urlSession)

        // Backfill is the caller with no head of its own yet.
        let page = try await client.transactionHistory(
            owner,
            request: BlockchainTransactionHistoryRequest(direction: .descending, lowerBound: 0, limit: 10)
        )

        #expect(page.transactions.isEmpty)
        #expect(page.reachedBoundary)
        #expect(page.head == 9876)
    }

    @Test func aForwardPassResumesPastTheNewestTransactionItSaw() async throws {
        let response = """
        [{
          "block_height":123,
          "block_time":456,
          "tx_hash":"transaction-hash",
          "tx_index":7
        }]
        """
        let stub = StubURLProtocol.makeSession(response: .success(body: Data(response.utf8)))
        let client = CardanoClient(endpoint: endpoint, projectId: "project-id", session: stub.urlSession)

        let first = try await client.transactionHistory(
            descriptor(),
            request: BlockchainTransactionHistoryRequest(direction: .ascending, lowerBound: 100, limit: 10)
        )

        var query = try queryItems(of: stub)
        #expect(query.contains(URLQueryItem(name: "order", value: "asc")))
        #expect(query.contains(URLQueryItem(name: "page", value: "1")))
        #expect(query.contains(URLQueryItem(name: "from", value: "100")))
        #expect(first.reachedBoundary)

        let second = try await client.transactionHistory(
            descriptor(),
            request: BlockchainTransactionHistoryRequest(
                cursor: first.nextCursor,
                direction: .ascending,
                lowerBound: 124,
                limit: 10
            )
        )

        // The next pass picks up right after block 123's 7th transaction,
        // rather than at the account's oldest page.
        query = try queryItems(of: stub)
        #expect(query.contains(URLQueryItem(name: "from", value: "123:8")))
        #expect(query.contains(URLQueryItem(name: "page", value: "1")))
        #expect(second.reachedBoundary)
        // The page carried a block height, so no `blocks/latest` read followed it.
        #expect(!stub.capturedRequests.contains { $0.url?.path.hasSuffix("/blocks/latest") == true })
    }

    @Test func backfillPagesArePinnedToTheHeadItStartedFrom() async throws {
        let response = """
        [{
          "block_height":123,
          "block_time":456,
          "tx_hash":"transaction-hash",
          "tx_index":7
        }]
        """
        let stub = StubURLProtocol.makeSession(response: .success(body: Data(response.utf8)))
        let client = CardanoClient(endpoint: endpoint, projectId: "project-id", session: stub.urlSession)

        let first = try await client.transactionHistory(
            descriptor(),
            request: BlockchainTransactionHistoryRequest(direction: .descending, upperBound: 900, limit: 1)
        )

        var query = try queryItems(of: stub)
        #expect(query.contains(URLQueryItem(name: "order", value: "desc")))
        #expect(query.contains(URLQueryItem(name: "page", value: "1")))
        #expect(query.contains(URLQueryItem(name: "to", value: "900")))
        // A full page — the scan continues.
        #expect(!first.reachedBoundary)

        _ = try await client.transactionHistory(
            descriptor(),
            request: BlockchainTransactionHistoryRequest(
                cursor: first.nextCursor,
                direction: .descending,
                upperBound: 900,
                limit: 1
            )
        )

        query = try queryItems(of: stub)
        #expect(query.contains(URLQueryItem(name: "page", value: "2")))
        #expect(query.contains(URLQueryItem(name: "to", value: "900")))
    }
}

private extension CardanoClientTests {
    func descriptor() throws -> CardanoAccountDescriptor {
        try CardanoAccountDescriptor(entropy: entropy, network: .preprod, path: .cardanoAccount(accountIndex: 0))
    }

    func queryItems(of stub: StubURLProtocol.Session) throws -> [URLQueryItem] {
        let historyRequest = stub.capturedRequests.last { $0.url?.path.hasSuffix("/transactions") == true }
        let url = try #require(historyRequest?.url)
        return try #require(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems)
    }
}
