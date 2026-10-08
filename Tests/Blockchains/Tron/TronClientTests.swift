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
        #expect(body["amount"] as? String == "42")
        #expect(body["visible"] as? Bool == true)
    }

    @Test func getNativeBalanceUsesTronGridAPIKey() async throws {
        let stub = StubURLProtocol.makeSession(response: .success(body: Data(#"{"balance":1234567}"#.utf8)))
        let client = TronClient(endpoint: endpoint, apiKey: "test-key", session: stub.urlSession)

        #expect(try await client.getNativeBalance(owner) == 1_234_567)
        #expect(stub.capturedRequest?.value(forHTTPHeaderField: "TRON-PRO-API-KEY") == "test-key")
        #expect(stub.capturedRequest?.url?.path == "/wallet/getaccount")
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

    @Test func transactionHistoryReportsHeadFromNativeTransactionsSoForwardSyncCanStart() async throws {
        let nativeBody = Data(#"""
        {"data":[{"txID":"abc","blockNumber":100,"block_timestamp":1000,"raw_data":{"contract":[]}}]}
        """#.utf8)
        let trc20Body = Data(#"{"data":[]}"#.utf8)
        let stub = StubURLProtocol.makeSession(responsesByPath: [
            "/v1/accounts/\(owner.string)/transactions": .success(body: nativeBody),
            "/v1/accounts/\(owner.string)/transactions/trc20": .success(body: trc20Body)
        ])
        let client = TronClient(endpoint: endpoint, session: stub.urlSession)

        let page = try await client.transactionHistory(
            owner,
            request: BlockchainTransactionHistoryRequest(direction: .descending, limit: 20)
        )

        #expect(page.head == 100)
    }

    private func requestBody(_ stub: StubURLProtocol.Session) throws -> [String: Any] {
        let body = try #require(stub.capturedBody)
        return try #require(JSONSerialization.jsonObject(with: body) as? [String: Any])
    }
}
