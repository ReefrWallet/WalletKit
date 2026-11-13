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

    private func pending(seqno: UInt32 = 5, validUntil: UInt32 = 1_700_000_600) -> TonPendingSend {
        TonPendingSend(
            normalizedHash: String(repeating: "ab", count: 32),
            sender: wallet.string,
            seqno: seqno,
            signedMessage: Data([1, 2, 3]),
            validUntil: validUntil
        )
    }

    private func transport(seqno: Int, indexed: Bool, submitted: Bool = true) -> FakeTonTransport {
        let transport = FakeTonTransport()
        transport.route("getAddressInformation", #"{"ok":true,"result":{"balance":"1","state":"active"}}"#)
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

    @Test func aDelayedIndexerKeepsTheOutcomeUnresolvedUntilTheGraceEnds() async throws {
        let transport = transport(seqno: 6, indexed: false)
        let client = TonClient(network: .testnet, transport: transport)
        #expect(try await client.reconcile(pending(), now: now) == .unresolved)
        // Expired, but inside the indexing grace: the message may still have been processed.
        let expired = now.addingTimeInterval(601)
        #expect(try await client.reconcile(pending(), now: expired) == .unresolved)
        let after = now.addingTimeInterval(600 + TonClient.indexingGrace + 1)
        #expect(try await client.reconcile(pending(), now: after) == .unprocessed)
        #expect(sendBocCount(transport) == 0)
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
