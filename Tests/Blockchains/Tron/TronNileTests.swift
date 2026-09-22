import Foundation
import Testing
import WalletKit

private let hasTronGridAPIKey = !(ProcessInfo.processInfo.environment["TRONGRID_API_KEY"] ?? "").isEmpty
private let nileTestAccount = "TGtcCdz2aV9vvCEtQL5BY8z2BnLi4oJ3sK"

@Suite(.timeLimit(.minutes(1)))
struct TronNileTests {
    @Test(.enabled(if: hasTronGridAPIKey))
    func fetchesTheFundedNileAccountThroughTronGrid() async throws {
        let address = try TronAddress(string: nileTestAccount)
        let apiKey = try #require(ProcessInfo.processInfo.environment["TRONGRID_API_KEY"])
        let client = TronClient(endpoint: TronNetwork.testnet.rpcURL, apiKey: apiKey)

        let balance = try await client.getNativeBalance(address)
        #expect(balance > 0)
        #expect(try await client.isActiveAccount(address))
    }

    @Test(.enabled(if: hasTronGridAPIKey))
    func fetchesHistoryForTheFundedNileAccountThroughTronGrid() async throws {
        let address = try TronAddress(string: nileTestAccount)
        let apiKey = try #require(ProcessInfo.processInfo.environment["TRONGRID_API_KEY"])
        let client = TronClient(endpoint: TronNetwork.testnet.rpcURL, apiKey: apiKey)

        let page = try await client.transactionHistory(
            address,
            request: BlockchainTransactionHistoryRequest(direction: .descending, limit: 20)
        )
        #expect(!page.transactions.isEmpty)
    }
}
