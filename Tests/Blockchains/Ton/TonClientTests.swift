import BigInt
import Foundation
import Testing
@testable import WalletKit

/// Serves canned toncenter responses by URL path and records every request.
final class FakeTonTransport: TonTransport, @unchecked Sendable {
    private let lock = NSLock()
    private var routes: [String: Data] = [:]
    private var recorded: [(url: URL, body: Data?)] = []

    var requests: [(url: URL, body: Data?)] {
        lock.withLock { recorded }
    }

    func route(_ path: String, _ json: String) {
        lock.withLock { routes[path] = Data(json.utf8) }
    }

    func get(_ url: URL) async throws -> Data {
        try respond(url, body: nil)
    }

    func post(_ url: URL, body: Data) async throws -> Data {
        try respond(url, body: body)
    }

    private func respond(_ url: URL, body: Data?) throws -> Data {
        try lock.withLock {
            recorded.append((url, body))

            guard let data = routes[url.lastPathComponent] else {
                throw BlockchainClientError.transportError(reason: "no route for \(url.lastPathComponent)")
            }

            return data
        }
    }
}

struct TonClientTests {
    private let privateKey: PrivateKey
    private let signer: TonPKeySigner
    private let wallet: TonAddress
    private let recipient: TonAddress

    init() throws {
        privateKey = try Mnemonic.generate().toSeed().masterKey(curve: .ed25519).privateKey()
        signer = try TonPKeySigner(
            network: .testnet,
            privateKey: privateKey,
            derivationPath: DerivationPath(.ton(.testnet), accountIndex: 0, curve: .ed25519)
        )

        wallet = try signer.address()
        recipient = try TonAddress(string: "EQCD39VS5jcptHL8vMjEXrzGaRcCVYto7HUn4bpAOg8xqB2N")
    }

    private func builder(_ transport: FakeTonTransport) -> TonTransactionBuilder {
        TonTransactionBuilder(
            client: TonClient(network: .testnet, transport: transport),
            publicKey: privateKey.publicKey.rawBytes,
            now: { Date(timeIntervalSince1970: 1_700_000_000) }
        )
    }

    private func addressInformation(balance: String, state: String) -> String {
        #"{"ok":true,"result":{"balance":"\#(balance)","state":"\#(state)"}}"#
    }

    @Test func firstSendOfAnUndeployedWalletCarriesTheStateInit() async throws {
        let transport = FakeTonTransport()
        transport.route("getAddressInformation", addressInformation(balance: "5000000000", state: "uninitialized"))
        let data = try await builder(transport).buildTransfer(
            sender: wallet,
            recipient: recipient,
            amount: BigUInt(1_000_000_000)
        )

        let transaction = try JSONDecoder().decode(TonUnsignedTransaction.self, from: data)

        #expect(transaction.seqno == 0)
        #expect(transaction.stateInit != nil)
        #expect(transaction.validUntil == 1_700_000_600)
        let stateInit = try #require(transaction.stateInit)
        #expect(try TonBOC.parse(stateInit).hash == wallet.hash)
    }

    @Test func aDeployedWalletReadsItsSeqnoAndSendsNoStateInit() async throws {
        let transport = FakeTonTransport()
        transport.route("getAddressInformation", addressInformation(balance: "5000000000", state: "active"))
        transport.route("runGetMethod", #"{"ok":true,"result":{"exit_code":0,"stack":[["num","0x2a"]]}}"#)
        let data = try await builder(transport).buildTransfer(
            sender: wallet,
            recipient: recipient,
            amount: BigUInt(1)
        )

        let transaction = try JSONDecoder().decode(TonUnsignedTransaction.self, from: data)

        #expect(transaction.seqno == 42)
        #expect(transaction.stateInit == nil)
    }

    @Test func signsTheBodyHashAndBroadcastsOneExternalMessage() async throws {
        let transport = FakeTonTransport()
        transport.route("getAddressInformation", addressInformation(balance: "5000000000", state: "uninitialized"))
        transport.route("sendBoc", #"{"ok":true,"result":{"@type":"ok"}}"#)
        let client = TonClient(network: .testnet, transport: transport)
        let data = try await builder(transport).buildTransfer(sender: wallet, recipient: recipient, amount: 1)
        let transaction = try JSONDecoder().decode(TonUnsignedTransaction.self, from: data)

        let signature = try await signer.sign(transaction: data)
        #expect(privateKey.publicKey.verify(signature: signature, message: try transaction.signingHash()))

        let identifier = try await client.broadcast(transaction: data, signature: signature)
        #expect(identifier == (try transaction.normalizedHash(signature: signature)))
        #expect(identifier.count == 64)

        let sent = try #require(transport.requests.last)
        #expect(sent.url.lastPathComponent == "sendBoc")
        let sentBody = try #require(sent.body)
        let boc = try #require(JSONDecoder().decode([String: String].self, from: sentBody)["boc"])
        let bocData = try #require(Data(base64Encoded: boc))
        let message = try TonBOC.parse(bocData)
        // The state init and the body are inline: the two code and data cells, then the action list.
        #expect(message.refs.count == 3)
    }

    @Test func rejectsASenderThatIsNotTheKeysWallet() async throws {
        let transport = FakeTonTransport()
        await #expect(throws: WalletKitError.self) {
            _ = try await builder(transport).buildTransfer(sender: recipient, recipient: wallet, amount: 1)
        }
    }

    @Test func refusesWhenTheBalanceIsTooLow() async throws {
        let transport = FakeTonTransport()
        transport.route("getAddressInformation", addressInformation(balance: "10", state: "active"))
        await #expect(throws: BlockchainTransactionBuilderError.self) {
            _ = try await builder(transport).buildTransfer(sender: wallet, recipient: recipient, amount: 11)
        }
    }

    @Test func aRawRecipientIsBouncedOnlyWhenVerifiedDeployed() async throws {
        let transport = FakeTonTransport()
        let raw = try TonAddress(string: recipient.rawString)
        transport.route("getAddressInformation", addressInformation(balance: "5000000000", state: "uninitialized"))
        let data = try await builder(transport).buildTransfer(sender: wallet, recipient: raw, amount: 1)
        let transaction = try JSONDecoder().decode(TonUnsignedTransaction.self, from: data)
        let action = try TonBOC.parse(transaction.body).refs[0]
        let message = action.refs[1]
        // int_msg_info$0 ihr_disabled bounce bounced: the bounce bit is the third bit.
        #expect(message.bits[0] & 0b0010_0000 == 0)
    }

    @Test func aFailedRecipientLookupIsNotDefaultedForRawAddresses() async throws {
        let transport = FakeTonTransport()
        let raw = try TonAddress(string: recipient.rawString)
        transport.route("getAddressInformation", #"{"ok":false,"error":"timeout","code":500}"#)
        await #expect(throws: BlockchainClientError.self) {
            _ = try await builder(transport).buildTransfer(sender: wallet, recipient: raw, amount: 1)
        }
    }

    @Test func rejectsAMainnetOnlyUseOfATestnetTag() throws {
        let client = TonClient(network: .mainnet, transport: FakeTonTransport())
        #expect(throws: WalletKitError.self) { _ = try client.makeAddress(wallet.string) }
    }

    @Test func historyPagesByLogicalTimeAndIdentifiesExternalRequestsByNormalizedHash() async throws {
        let transport = FakeTonTransport()
        let hash = Data(repeating: 1, count: 32).base64EncodedString()
        let normalized = Data(repeating: 2, count: 32).base64EncodedString()
        transport.route("transactions", """
        {"transactions":[
        {"hash":"\(hash)","lt":"500","now":1700000000,"total_fees":"100",
         "description":{"aborted":false,"compute_ph":{"success":true}},
         "in_msg":{"hash":"\(hash)","hash_norm":"\(normalized)","source":null,"destination":"\(wallet.rawString)","value":null},
         "out_msgs":[{"hash":"\(hash)","source":"\(wallet.rawString)","destination":"\(recipient.rawString)","value":"7"}]}
        ],"address_book":{}}
        """)
        let client = TonClient(network: .testnet, transport: transport)
        let page = try await client.transactionHistory(
            wallet,
            request: BlockchainTransactionHistoryRequest(direction: .descending, limit: 1)
        )

        let transaction = try #require(page.transactions.first)
        #expect(transaction.identifier == Data(repeating: 2, count: 32).map { String(format: "%02x", $0) }.joined())
        #expect(transaction.status == .confirmed)
        #expect(transaction.effects.first?.amount == "7")
        #expect(page.head == 500)
        #expect(!page.reachedBoundary)

        let cursor = try #require(page.nextCursor)
        #expect(try JSONDecoder().decode(TonClient.HistoryCursor.self, from: cursor).next == 499)
    }

    @Test func aRequestThatRanButSentNothingIsNotAPayment() async throws {
        let transport = FakeTonTransport()
        let hash = Data(repeating: 1, count: 32).base64EncodedString()
        transport.route("transactions", """
        {"transactions":[
        {"hash":"\(hash)","lt":"9","now":1700000000,
         "description":{"aborted":false,"compute_ph":{"success":true}},
         "in_msg":{"hash":"\(hash)","source":null,"destination":"\(wallet.rawString)","value":null},
         "out_msgs":[]}],"address_book":{}}
        """)
        let page = try await TonClient(network: .testnet, transport: transport).transactionHistory(
            wallet,
            request: BlockchainTransactionHistoryRequest(direction: .descending)
        )
        #expect(page.transactions.first?.status == .failed)
    }

    @Test func deliveryToAnUndeployedRecipientWithSkippedComputeCountsAsDelivered() async throws {
        let transport = FakeTonTransport()
        let hash = Data(repeating: 1, count: 32).base64EncodedString()
        let client = TonClient(network: .testnet, transport: transport)

        transport.route("transactionsByMessage", #"{"transactions":[],"address_book":{}}"#)
        #expect(try await client.deliveryStatus(ofOutgoingMessage: hash) == .pending)

        transport.route("transactionsByMessage", """
        {"transactions":[{"hash":"\(hash)","lt":"1","description":{"aborted":true,
        "compute_ph":{"skipped":true,"reason":"no_state"}},"in_msg":{"hash":"\(hash)"},"out_msgs":[]}],
        "address_book":{}}
        """)
        #expect(try await client.deliveryStatus(ofOutgoingMessage: hash) == .delivered)

        transport.route("transactionsByMessage", """
        {"transactions":[{"hash":"\(hash)","lt":"1","description":{"aborted":true,"bounce":{"type":"ok"}},
        "in_msg":{"hash":"\(hash)"},"out_msgs":[]}],"address_book":{}}
        """)
        #expect(try await client.deliveryStatus(ofOutgoingMessage: hash) == .bounced)
    }
}
