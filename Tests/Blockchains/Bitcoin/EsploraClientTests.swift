// Tests for Sources/WalletKit/Blockchains/Bitcoin/EsploraClient.swift. Uses
// `StubURLProtocol` exactly like `JSONRPCClientTests`/`EthereumRPCClientTests`
// — exercises the real `URLSession`/Moya pipeline without a real network call.

import Foundation
import Testing
@testable import WalletKit
import WalletKitRust

struct EsploraClientTests {
    /// A minimal, syntactically valid (if semantically meaningless)
    /// non-SegWit raw transaction — one zero-filled input, one zero-value
    /// output — built programmatically rather than as a long hand-counted
    /// hex literal.
    private var minimalRawTransactionHex: String {
        "01000000" // version
            + "01" // input count
            + String(repeating: "00", count: 32) // prevout txid
            + "ffffffff" // prevout vout
            + "00" // scriptSig length
            + "ffffffff" // sequence
            + "01" // output count
            + String(repeating: "00", count: 8) // value
            + "00" // scriptPubkey length
            + "00000000" // locktime
    }

    private func makeClient(_ stub: StubURLProtocol.Session) -> EsploraClient {
        EsploraClient(endpoint: URL(string: "https://example.com")!, session: stub.urlSession)
    }

    @Test func addressStatsDecodesSnakeCaseFieldsViaExplicitCodingKeys() async throws {
        let body = """
        {"chain_stats":{"funded_txo_sum":500,"spent_txo_sum":200},
        "mempool_stats":{"funded_txo_sum":0,"spent_txo_sum":0}}
        """
        let stub = StubURLProtocol.makeSession(response: .success(body: Data(body.utf8)))

        let stats = try await makeClient(stub).addressStats("bc1qsomeaddress")
        #expect(stats.chainStats.fundedTxoSum == 500)
        #expect(stats.chainStats.spentTxoSum == 200)

        let request = try #require(stub.capturedRequest)
        #expect(request.url?.path == "/address/bc1qsomeaddress")
    }

    @Test func tipHeightParsesThePlainTextResponse() async throws {
        let stub = StubURLProtocol.makeSession(response: .success(body: Data("871234".utf8)))
        let height = try await makeClient(stub).tipHeight()
        #expect(height == 871_234)
    }

    @Test func tipHeightThrowsDecodingFailedOnMalformedText() async throws {
        let stub = StubURLProtocol.makeSession(response: .success(body: Data("not-a-number".utf8)))

        do {
            _ = try await makeClient(stub).tipHeight()
            Issue.record("expected tipHeight() to throw")
        } catch let error as BlockchainClientError {
            guard case .decodingFailed = error else {
                Issue.record("expected .decodingFailed, got \(error)")
                return
            }
        }
    }

    @Test func rawTransactionDecodesHexPlainTextIntoData() async throws {
        let stub = StubURLProtocol.makeSession(response: .success(body: Data("deadbeef".utf8)))
        let data = try await makeClient(stub).rawTransaction("sometxid")
        #expect(data == Data([0xDE, 0xAD, 0xBE, 0xEF]))
    }

    @Test func broadcastPostsTheRawHexAndReturnsTheTrimmedTxid() async throws {
        let stub = StubURLProtocol.makeSession(response: .success(body: Data("  abc123txid  ".utf8)))
        let result = try await makeClient(stub).broadcast(rawTransactionHex: minimalRawTransactionHex)

        #expect(result == "abc123txid")
        #expect(stub.capturedBody == Data(minimalRawTransactionHex.utf8))
        #expect(stub.capturedRequest?.httpMethod == "POST")
    }

    @Test func broadcastThrowsInvalidResponseOnAGenuineRejection() async throws {
        let stub = StubURLProtocol.makeSession(
            response: .success(statusCode: 400, body: Data("bad-txns-inputs-missingorspent".utf8))
        )

        do {
            _ = try await makeClient(stub).broadcast(rawTransactionHex: minimalRawTransactionHex)
            Issue.record("expected broadcast(rawTransactionHex:) to throw")
        } catch let error as BlockchainClientError {
            guard case .invalidResponse = error else {
                Issue.record("expected .invalidResponse, got \(error)")
                return
            }
        }
    }

    /// Covers the ambiguous-retry case: a 429/503 retry can land on an
    /// already-known-shaped rejection even though the first attempt
    /// landed. The canonical txid is deterministic from the raw bytes
    /// (decoded the same way `ElectrumClient` does, not a hash of the
    /// complete signed bytes — that would be the SegWit wtxid), so it's
    /// recovered locally instead of surfacing a false failure.
    @Test func broadcastRecoversTheTxidLocallyWhenAlreadyKnown() async throws {
        let stub = StubURLProtocol.makeSession(
            response: .success(statusCode: 400, body: Data("txn-already-known".utf8))
        )

        let result = try await makeClient(stub).broadcast(rawTransactionHex: minimalRawTransactionHex)

        let expectedTxid = try bitcoinDecodeTransaction(raw: Data(hexString: minimalRawTransactionHex)).txid
        #expect(result == expectedTxid)
    }
}
