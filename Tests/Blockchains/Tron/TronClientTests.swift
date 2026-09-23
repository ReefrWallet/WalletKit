import BigInt
import Foundation
import Testing
@testable import WalletKit

struct TronClientTests {
    private let endpoint = URL(string: "https://example.com")!
    private let owner = try! TronAddress(string: "TGtcCdz2aV9vvCEtQL5BY8z2BnLi4oJ3sK") // swiftlint:disable:this force_try

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
        let stub = StubURLProtocol.makeSession(response: .success(body: Data(#"{"constant_result":["000000000000000000000000000000000000000000000000000000000000002a"]}"#.utf8)))
        let client = TronClient(endpoint: endpoint, session: stub.urlSession)
        let token = "TXYZopYRdj2D9XRtbG411XZZ3kM5VkAeBf"

        #expect(try await client.getBalance(owner, token: token) == 42)
        let body = try requestBody(stub)
        #expect(stub.capturedRequest?.url?.path == "/wallet/triggerconstantcontract")
        #expect(body["function_selector"] as? String == "balanceOf(address)")
        #expect((body["parameter"] as? String)?.count == 64)
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
