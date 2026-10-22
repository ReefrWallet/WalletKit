import BigInt
import Foundation
import Testing
@testable import WalletKit

struct TronClientTests {
    private let endpoint = URL(string: "https://example.com")!
    // swiftlint:disable:next force_try
    private let owner = try! TronAddress(string: "TGtcCdz2aV9vvCEtQL5BY8z2BnLi4oJ3sK")

    @Test func buildNativeTransferSendsVisibleTronGridRequest() async throws {
        let stub = StubURLProtocol.makeSession(response: .success(body: Data(#"{"raw_data_hex":"00"}"#.utf8)))
        let client = TronClient(endpoint: endpoint, session: stub.urlSession)
        let recipient = try TronAddress(string: "T9yD14Nj9j7xAB4dbGeiX9h8unkKHxuWwb")

        _ = try await TronTransactionBuilder(client: client).buildTransfer(
            sender: owner,
            recipient: recipient,
            amount: 42,
            token: nil,
            options: []
        )

        #expect(stub.capturedRequest?.url?.path == "/wallet/createtransaction")
        let body = try requestBody(stub)
        #expect(body["owner_address"] as? String == owner.string)
        #expect(body["to_address"] as? String == recipient.string)
        #expect(body["amount"] as? UInt64 == 42)
        #expect(body["visible"] as? Bool == true)
    }

    @Test func getNativeBalanceUsesTronGridAPIKey() async throws {
        let stub = StubURLProtocol.makeSession(response: .success(body: Data(#"{"balance":1234567}"#.utf8)))
        let client = TronClient(endpoint: endpoint, apiKey: "test-key", session: stub.urlSession)

        #expect(try await client.getNativeBalance(owner) == 1_234_567)
        #expect(stub.capturedRequest?.value(forHTTPHeaderField: "TRON-PRO-API-KEY") == "test-key")
        #expect(stub.capturedRequest?.url?.path == "/wallet/getaccount")
    }

    @Test func relayPostsTheBodyWithTheAPIKeyAndReturnsTheRawResponse() async throws {
        let response = Data(#"{"balance":7}"#.utf8)
        let stub = StubURLProtocol.makeSession(response: .success(body: response))
        let client = TronClient(endpoint: endpoint, apiKey: "test-key", session: stub.urlSession)

        let data = try await client.relay(path: "wallet/getaccount", body: Data(#"{"visible":true}"#.utf8))

        #expect(data == response)
        #expect(stub.capturedRequest?.httpMethod == "POST")
        #expect(stub.capturedRequest?.url?.path == "/wallet/getaccount")
        #expect(stub.capturedRequest?.value(forHTTPHeaderField: "TRON-PRO-API-KEY") == "test-key")
        #expect(try requestBody(stub)["visible"] as? Bool == true)
    }

    /// One stubbed body answers all three calls (dry run, resources,
    /// chain parameters).
    @Test func estimateFeeBurnsEnergyBeyondTheAccountsResources() async throws {
        let response = #"""
        {"energy_used": 30000, "EnergyLimit": 10000, "EnergyUsed": 0, "freeNetLimit": 600, "freeNetUsed": 0,
         "chainParameter": [{"key": "getEnergyFee", "value": 100}, {"key": "getTransactionFee", "value": 1000}]}
        """#
        let stub = StubURLProtocol.makeSession(response: .success(body: Data(response.utf8)))
        let client = TronClient(endpoint: endpoint, session: stub.urlSession)
        let transaction = try TronRawTransaction(rawBytes: Data(hexString: TronRawTransactionTests.triggerHex))

        let fee = try await client.estimateFee(for: transaction)

        #expect(fee.energy == 30_000)
        #expect(fee.bandwidth == UInt64(transaction.rawBytes.count) + 135)
        // (30 000 - 10 000) energy × 100 SUN; bandwidth fits in the free 600.
        #expect(fee.burnedSun == 2_000_000)
    }

    @Test func relayGetsWithQueryItems() async throws {
        let stub = StubURLProtocol.makeSession(response: .success(body: Data("{}".utf8)))
        let client = TronClient(endpoint: endpoint, session: stub.urlSession)

        _ = try await client.relay(
            path: "v1/blocks/1/events",
            query: [URLQueryItem(name: "limit", value: "20")],
            body: nil
        )

        #expect(stub.capturedRequest?.httpMethod == "GET")
        #expect(stub.capturedRequest?.url?.absoluteString == "https://example.com/v1/blocks/1/events?limit=20")
    }

    @Test func getTRC20BalanceEncodesBalanceOfCall() async throws {
        let response = #"{"constant_result":["000000000000000000000000000000000000000000000000000000000000002a"]}"#
        let stub = StubURLProtocol.makeSession(response: .success(body: Data(response.utf8)))
        let client = TronClient(endpoint: endpoint, session: stub.urlSession)
        let token = "TXYZopYRdj2D9XRtbG411XZZ3kM5VkAeBf"

        #expect(try await client.getBalance(owner, token: token) == 42)
        let body = try requestBody(stub)
        #expect(stub.capturedRequest?.url?.path == "/wallet/triggerconstantcontract")
        #expect(body["function_selector"] as? String == "balanceOf(address)")
        #expect((body["parameter"] as? String)?.count == 64)
    }

    @Test func broadcastReturnsTheNodesTxidOnSuccess() async throws {
        let stub = StubURLProtocol.makeSession(
            response: .success(body: Data(#"{"result":true,"txid":"node-txid"}"#.utf8))
        )

        let client = TronClient(endpoint: endpoint, session: stub.urlSession)
        let transaction = Data(#"{"raw_data_hex":"00","txID":"unsigned-txid"}"#.utf8)

        let result = try await client.broadcast(transaction: transaction, signature: Data(repeating: 0xAB, count: 65))
        #expect(result == "node-txid")
    }

    @Test func broadcastThrowsOnAGenuineRejection() async throws {
        let stub = StubURLProtocol.makeSession(
            response: .success(
                body: Data(#"{"result":false,"code":"CONTRACT_VALIDATE_ERROR","message":"626164"}"#.utf8)
            )
        )

        let client = TronClient(endpoint: endpoint, session: stub.urlSession)
        let transaction = Data(#"{"raw_data_hex":"00","txID":"unsigned-txid"}"#.utf8)

        do {
            _ = try await client.broadcast(transaction: transaction, signature: Data(repeating: 0xAB, count: 65))
            Issue.record("expected broadcast(transaction:signature:) to throw")
        } catch let error as WalletKitError {
            guard case .internalError = error else {
                Issue.record("expected .internalError, got \(error)")
                return
            }
        }
    }

    /// Covers the ambiguous-retry case: a 429/503 retry can land on
    /// "DUP_TRANSACTION_ERROR" even though the first attempt landed. The
    /// txID is already known from the unsigned payload (java-tron's own
    /// identifier for the transaction it already built), so it's recovered
    /// instead of surfacing a false failure.
    @Test func broadcastRecoversTheKnownTxidOnADuplicateRejection() async throws {
        // "64 75 70 6c 69 63 61 74 65" == "duplicate", hex-encoded the way
        // java-tron encodes error messages.
        let stub = StubURLProtocol.makeSession(
            response: .success(
                body: Data(#"{"result":false,"code":"DUP_TRANSACTION_ERROR","message":"6475706c6963617465"}"#.utf8)
            )
        )

        let client = TronClient(endpoint: endpoint, session: stub.urlSession)
        let transaction = Data(#"{"raw_data_hex":"00","txID":"unsigned-txid"}"#.utf8)

        let result = try await client.broadcast(transaction: transaction, signature: Data(repeating: 0xAB, count: 65))
        #expect(result == "unsigned-txid")
    }

    @Test func mainnetAndNileUseTronGridEndpoints() {
        #expect(TronNetwork.mainnet.rpcURL == URL(string: "https://api.trongrid.io")!)
        #expect(TronNetwork.testnet.rpcURL == URL(string: "https://nile.trongrid.io")!)
    }

    @Test func transactionHistoryReportsSolidifiedHeadEvenWithoutNativeTransactions() async throws {
        let stub = StubURLProtocol.makeSession(responsesByPath: historyResponses(trc20: "[]"))
        let client = TronClient(endpoint: endpoint, session: stub.urlSession)

        let page = try await client.transactionHistory(
            owner,
            request: BlockchainTransactionHistoryRequest(direction: .descending, limit: 20)
        )

        #expect(page.head == 500)
        #expect(page.reachedBoundary)
    }

    @Test func transactionHistoryResolvesTokenTransferBlockHeights() async throws {
        let trc20 = #"""
        [{"transaction_id":"tok","token_info":{"address":"TR7NHqjeKQxGTCi8q8ZY4pL8otSzgjLj6t"},
          "block_timestamp":1000,"from":"TA","to":"\#(owner.string)","value":"5"}]
        """#
        var responses = historyResponses(trc20: trc20)
        responses["/walletsolidity/gettransactioninfobyid"] = .success(body: Data(#"{"blockNumber":321}"#.utf8))
        let stub = StubURLProtocol.makeSession(responsesByPath: responses)
        let client = TronClient(endpoint: endpoint, session: stub.urlSession)

        let page = try await client.transactionHistory(
            owner,
            request: BlockchainTransactionHistoryRequest(direction: .descending, limit: 20)
        )

        #expect(page.transactions.map(\.blockHeight) == [321])
    }

    @Test func transactionHistoryDecodesTRC20TransferFromTheContractCall() async throws {
        let token = try TronAddress(string: "TR7NHqjeKQxGTCi8q8ZY4pL8otSzgjLj6t")
        let recipient = try TronAddress(string: "T9yD14Nj9j7xAB4dbGeiX9h8unkKHxuWwb")
        let data = "a9059cbb" + String(repeating: "0", count: 24) + recipient.rawBytes.dropFirst().bareHex
            + String(5, radix: 16).leftPadding(to: 64)
        let native = #"""
        {"data":[{"txID":"call","blockNumber":321,"block_timestamp":1000,"raw_data":{"contract":[
          {"type":"TriggerSmartContract","parameter":{"value":{"owner_address":"\#(owner.rawBytes.bareHex)",
           "contract_address":"\#(token.rawBytes.bareHex)","data":"\#(data)"}}}]},"ret":[{"contractRet":"SUCCESS"}]}]}
        """#
        let indexed = #"""
        [{"transaction_id":"call","token_info":{"address":"\#(token.string)"},"block_timestamp":1000,
          "from":"\#(owner.string)","to":"\#(recipient.string)","value":"5"}]
        """#

        for trc20 in ["[]", indexed] {
            var responses = historyResponses(trc20: trc20)
            responses["/v1/accounts/\(owner.string)/transactions"] = .success(body: Data(native.utf8))
            let stub = StubURLProtocol.makeSession(responsesByPath: responses)
            let client = TronClient(endpoint: endpoint, session: stub.urlSession)

            let page = try await client.transactionHistory(
                owner,
                request: BlockchainTransactionHistoryRequest(direction: .descending, limit: 20)
            )

            let effects = try #require(page.transactions.first).effects
            #expect(effects.count == 1)
            #expect(effects.first?.kind == .tokenTransfer)
            #expect(effects.first?.assetIdentifier == token.string)
            #expect(effects.first?.amount == "5")
            #expect(effects.first?.to == recipient.string)
        }
    }

    @Test func transactionHistoryIncludesTronScanInternalTransfers() async throws {
        var responses = historyResponses(trc20: "[]")
        responses["/api/internal-transaction"] = .success(body: Data(#"""
        {"data":[
          {"hash":"swap","block":400,"timestamp":1000,"from":"TKzxdSv2FZKQrEqkKVgp5DcwEXBEKMg2Ax",
           "to":"\#(owner.string)","token_id":"_","call_value":134174645,"confirmed":true,"revert":false},
          {"hash":"other","block":401,"timestamp":1000,"from":"TA","to":"TB","token_id":"_","call_value":1}
        ]}
        """#.utf8))
        let stub = StubURLProtocol.makeSession(responsesByPath: responses)
        let client = TronClient(
            endpoint: endpoint,
            tronScanEndpoint: URL(string: "https://scan.example.com")!,
            session: stub.urlSession
        )

        let page = try await client.transactionHistory(
            owner,
            request: BlockchainTransactionHistoryRequest(direction: .descending, limit: 20)
        )

        let transaction = try #require(page.transactions.first)
        #expect(page.transactions.count == 1)
        #expect(transaction.identifier == "swap")
        #expect(transaction.blockHeight == 400)
        #expect(transaction.effects.first?.kind == .nativeTransfer)
        #expect(transaction.effects.first?.amount == "134174645")
        #expect(transaction.effects.first?.to == owner.string)
    }

    @Test func transactionHistorySurvivesAnUnreachableTronScan() async throws {
        let trc20 = #"""
        [{"transaction_id":"tok","token_info":{"address":"TR7NHqjeKQxGTCi8q8ZY4pL8otSzgjLj6t"},
          "block_timestamp":1000,"from":"TA","to":"\#(owner.string)","value":"5","block_number":7}]
        """#
        var responses = historyResponses(trc20: trc20)
        responses["/api/internal-transaction"] = .failure(.secureConnectionFailed)
        responses["/walletsolidity/gettransactioninfobyid"] = .success(body: Data(#"{"blockNumber":7}"#.utf8))
        let stub = StubURLProtocol.makeSession(responsesByPath: responses)
        let client = TronClient(
            endpoint: endpoint,
            tronScanEndpoint: URL(string: "https://scan.example.com")!,
            session: stub.urlSession
        )

        let page = try await client.transactionHistory(
            owner,
            request: BlockchainTransactionHistoryRequest(direction: .descending, limit: 20)
        )

        #expect(page.transactions.map(\.identifier) == ["tok"])
        #expect(page.reachedBoundary)
    }

    @Test func transactionHistoryPastTheSolidifiedHeadIsAnEmptyBoundaryPage() async throws {
        let stub = StubURLProtocol.makeSession(responsesByPath: historyResponses(trc20: "[]"))
        let client = TronClient(endpoint: endpoint, session: stub.urlSession)

        let page = try await client.transactionHistory(
            owner,
            request: BlockchainTransactionHistoryRequest(direction: .ascending, lowerBound: 501, limit: 20)
        )

        #expect(page.transactions.isEmpty)
        #expect(page.reachedBoundary)
        #expect(page.head == 500)
        #expect(stub.capturedRequest?.url?.path == "/walletsolidity/getblock")
    }

    private func historyResponses(trc20: String) -> [String: StubURLProtocol.StubResponse] {
        [
            "/walletsolidity/getblock": .success(
                body: Data(#"{"block_header":{"raw_data":{"number":500,"timestamp":1500000}}}"#.utf8)
            ),
            "/v1/accounts/\(owner.string)/transactions": .success(body: Data(#"{"data":[]}"#.utf8)),
            "/v1/accounts/\(owner.string)/transactions/trc20": .success(body: Data(#"{"data":\#(trc20)}"#.utf8))
        ]
    }

    private func requestBody(_ stub: StubURLProtocol.Session) throws -> [String: Any] {
        let body = try #require(stub.capturedBody)
        return try #require(JSONSerialization.jsonObject(with: body) as? [String: Any])
    }
}
