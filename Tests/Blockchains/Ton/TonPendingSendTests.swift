import Foundation
import Testing
@testable import WalletKit

struct TonPendingSendTests {
    private let wallet: TonAddress
    private let now = Date(timeIntervalSince1970: 1_700_000_000)

    init() throws {
        let key = try Mnemonic.generate().toSeed().masterKey(curve: .ed25519).privateKey().publicKey
        wallet = try TonAddress(publicKey: key, network: .testnet)
    }

    private func pending(
        seqno: UInt32 = 5,
        validUntil: UInt32 = 1_700_000_600,
        baselineLt: UInt64? = 50
    ) -> TonPendingSend {
        TonPendingSend(
            normalizedHash: String(repeating: "ab", count: 32),
            sender: wallet.string,
            seqno: seqno,
            signedMessage: Data([1, 2, 3]),
            validUntil: validUntil,
            baselineLt: baselineLt
        )
    }

    /// A wallet transaction as the indexer lists it; a request's hash is `0xab…` unless `hashNorm` says otherwise.
    private func walletTransaction(
        lt: Int,
        prev: Int,
        hashNorm: Data? = Data(repeating: 7, count: 32)
    ) -> String {
        let hash = Data(repeating: UInt8(lt % 200), count: 32).base64EncodedString()
        let norm = hashNorm.map { #","hash_norm":"\#($0.base64EncodedString())""# } ?? ""
        return """
        {"hash":"\(hash)","lt":"\(lt)","prev_trans_lt":"\(prev)",
         "in_msg":{"hash":"\(hash)"\(norm),"source":null},"out_msgs":[]}
        """
    }

    /// `chainLt` is the wallet's latest on-chain transaction; `transactions` what the indexer lists after the baseline.
    private func transport(
        seqno: Int,
        indexed: Bool,
        submitted: Bool = true,
        chainLt: Int = 100,
        transactions: [String] = []
    ) -> FakeTonTransport {
        let transport = FakeTonTransport()
        transport.route(
            "getAddressInformation",
            #"{"ok":true,"result":{"balance":"1","state":"active","last_transaction_id":{"lt":"\#(chainLt)"}}}"#
        )

        transport.route(
            "transactions",
            #"{"transactions":[\#(transactions.joined(separator: ","))],"address_book":{}}"#
        )

        transport.route("runGetMethod", #"{"ok":true,"result":{"exit_code":0,"stack":[["num","0x\#(String(seqno, radix: 16))"]]}}"#)
        transport.route("sendBoc", submitted ? #"{"ok":true,"result":{}}"# : #"{"ok":false,"error":"x","code":500}"#)
        let hash = Data(repeating: 1, count: 32).base64EncodedString()
        transport.route("transactionsByMessage", indexed
            ? #"{"transactions":[{"hash":"\#(hash)","lt":"1","in_msg":{"hash":"\#(hash)"}}],"address_book":{}}"#
            : #"{"transactions":[],"address_book":{}}"#)
        return transport
    }

    private func sendBocCount(_ transport: FakeTonTransport) -> Int {
        transport.requests.filter { $0.url.lastPathComponent == "sendBoc" }.count
    }

    @Test func aCurrentUnexpiredRequestIsResentUnchanged() async throws {
        let transport = transport(seqno: 5, indexed: false)
        let client = TonClient(network: .testnet, transport: transport)
        #expect(try await client.reconcile(pending(), now: now) == .pending)
        #expect(sendBocCount(transport) == 1)
        let sent = try #require(transport.requests.last?.body)
        let boc = try JSONDecoder().decode([String: String].self, from: sent)["boc"]
        #expect(boc == Data([1, 2, 3]).base64EncodedString())
    }

    @Test func anExpiredRequestWithTheSameSeqnoIsUnprocessedAndNotResent() async throws {
        let transport = transport(seqno: 5, indexed: false)
        let client = TonClient(network: .testnet, transport: transport)
        let late = now.addingTimeInterval(601)
        #expect(try await client.reconcile(pending(), now: late) == .unprocessed)
        #expect(sendBocCount(transport) == 0)
    }

    @Test func anAdvancedSeqnoWithAnIndexedMessageIsConfirmed() async throws {
        let transport = transport(seqno: 6, indexed: true)
        let client = TonClient(network: .testnet, transport: transport)
        #expect(try await client.reconcile(pending(), now: now) == .confirmed)
        #expect(sendBocCount(transport) == 0)
    }

    @Test func aGapInTheIndexedChainKeepsTheOutcomeUnresolvedHoweverLongItTakes() async throws {
        // The consuming transaction (lt 70) is not indexed: the newest visible one (100) points past the baseline.
        let transport = transport(seqno: 6, indexed: false, transactions: [walletTransaction(lt: 100, prev: 70)])
        let client = TonClient(network: .testnet, transport: transport)
        #expect(try await client.reconcile(pending(), now: now) == .unresolved)
        let muchLater = now.addingTimeInterval(86_400)
        #expect(try await client.reconcile(pending(), now: muchLater) == .unresolved)
        #expect(sendBocCount(transport) == 0)
    }

    @Test func aChainThatStopsShortOfTheChainHeadIsUnresolved() async throws {
        let transport = transport(seqno: 6, indexed: false, transactions: [walletTransaction(lt: 60, prev: 50)])
        let client = TonClient(network: .testnet, transport: transport)
        #expect(try await client.reconcile(pending(), now: now) == .unresolved)
    }

    @Test func aRecordWithoutABaselineIsNeverProvenUnprocessed() async throws {
        let transport = transport(seqno: 6, indexed: false, transactions: [walletTransaction(lt: 100, prev: 50)])
        let client = TonClient(network: .testnet, transport: transport)
        #expect(try await client.reconcile(pending(baselineLt: nil), now: now) == .unresolved)
    }

    @Test func anExternalRequestListedWithoutItsNormalizedHashLeavesTheOutcomeUnresolved() async throws {
        let chain = [walletTransaction(lt: 60, prev: 50, hashNorm: nil), walletTransaction(lt: 100, prev: 60)]
        let transport = transport(seqno: 6, indexed: false, transactions: chain)
        let client = TonClient(network: .testnet, transport: transport)
        #expect(try await client.reconcile(pending(), now: now) == .unresolved)
    }

    @Test func anUnbrokenChainWithoutTheMessageProvesItUnprocessed() async throws {
        let chain = [walletTransaction(lt: 60, prev: 50), walletTransaction(lt: 100, prev: 60)]
        let transport = transport(seqno: 6, indexed: false, transactions: chain)
        let client = TonClient(network: .testnet, transport: transport)
        #expect(try await client.reconcile(pending(), now: now) == .unprocessed)
        #expect(sendBocCount(transport) == 0)
    }

    @Test func anUnbrokenChainHoldingTheMessageConfirmsItEvenWhenTheHashLookupLags() async throws {
        let ours = Data(repeating: 0xab, count: 32)
        let chain = [walletTransaction(lt: 60, prev: 50, hashNorm: ours), walletTransaction(lt: 100, prev: 60)]
        let transport = transport(seqno: 6, indexed: false, transactions: chain)
        let client = TonClient(network: .testnet, transport: transport)
        #expect(try await client.reconcile(pending(), now: now) == .confirmed)
    }

    @Test func anUnreadableAnswerToASubmissionIsAmbiguous() async throws {
        let transport = transport(seqno: 5, indexed: false)
        transport.route("sendBoc", "<html>gateway</html>")
        let client = TonClient(network: .testnet, transport: transport)

        do {
            try await client.postBoc(Data([1]))
            Issue.record("Expected an error.")
        } catch {
            #expect(TonClient.isAmbiguous(error))
        }
    }

    @Test func anAcceptedSubmissionWithAnUnreadableAnswerIsReconciledAfterARestart() async throws {
        let first = transport(seqno: 5, indexed: false)
        first.route("sendBoc", "not json")
        let before = TonClient(network: .testnet, transport: first)
        let record = pending()

        // The answer is unreadable, so the caller keeps the persisted record instead of treating it as rejected.
        await #expect(throws: BlockchainClientError.self) { try await before.submit(record) }

        // After a restart only the persisted JSON is left; the wallet has consumed the seqno with our message.
        let restored = try JSONDecoder().decode(TonPendingSend.self, from: JSONEncoder().encode(record))
        let ours = Data(repeating: 0xab, count: 32)
        let chain = [walletTransaction(lt: 100, prev: 50, hashNorm: ours)]
        let after = TonClient(network: .testnet, transport: transport(seqno: 6, indexed: false, transactions: chain))
        #expect(try await after.reconcile(restored, now: now) == .confirmed)
    }

    @Test func aSubmissionIsNeverRetriedByTheTransport() async throws {
        let transport = transport(seqno: 5, indexed: false)
        let client = TonClient(network: .testnet, transport: transport)
        try await client.postBoc(Data([1]))
        #expect(transport.submissions == 1)
    }

    @Test func ambiguousFailuresAreClassifiedApartFromRejections() {
        #expect(TonClient.isAmbiguous(BlockchainClientError.transportError(reason: "x")))
        #expect(TonClient.isAmbiguous(BlockchainClientError.rpcError(code: 500, message: "x")))
        #expect(TonClient.isAmbiguous(BlockchainClientError.quotaExceeded(code: 429, message: "x", retryAfter: nil)))
        #expect(!TonClient.isAmbiguous(BlockchainClientError.rpcError(code: 400, message: "bad seqno")))
        #expect(!TonClient.isAmbiguous(WalletKitError.invalidAddress(reason: "x")))
    }

    @Test func aPendingSendRoundTripsThroughJSON() throws {
        let original = pending()
        let decoded = try JSONDecoder().decode(TonPendingSend.self, from: JSONEncoder().encode(original))
        #expect(decoded == original)
    }
}
