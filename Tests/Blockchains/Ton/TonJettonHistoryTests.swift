import BigInt
import Foundation
import Testing
@testable import WalletKit

/// Decodes the responses captured from the TON testnet (ton-jetton-captures.json): a delivered transfer to an
/// owner without a Jetton wallet, and an overspend that fails downstream.
struct TonJettonHistoryTests {
    private struct Captures: Decodable {
        let okAction: AnyJSON
        let failedActions: [AnyJSON]
        let failedTrace: AnyJSON
    }

    private struct AnyJSON: Codable {
        let value: Any

        init(from decoder: any Decoder) throws {
            let container = try decoder.singleValueContainer()

            if let object = try? container.decode([String: AnyJSON].self) {
                value = object.mapValues(\.value)
            } else if let array = try? container.decode([AnyJSON].self) {
                value = array.map(\.value)
            } else if let text = try? container.decode(String.self) {
                value = text
            } else if let number = try? container.decode(Int.self) {
                value = number
            } else if let flag = try? container.decode(Bool.self) {
                value = flag
            } else {
                value = NSNull()
            }
        }

        func encode(to encoder: any Encoder) throws {
            var container = encoder.singleValueContainer()
            try container.encode(String(data: try JSONSerialization.data(withJSONObject: value), encoding: .utf8))
        }

        var data: Data {
            get throws { try JSONSerialization.data(withJSONObject: value, options: [.fragmentsAllowed]) }
        }
    }

    private static let completeTrace =
        #"{"traces":[{"trace_id":"t","is_incomplete":false,"trace_info":{"trace_state":"complete"}}]}"#
    private static let runningTrace =
        #"{"traces":[{"trace_id":"t","is_incomplete":true,"trace_info":{"trace_state":"pending"}}]}"#

    private let captures: Captures
    private let recipient = "0QAY-pCOjxjflHjLmRlHnr98VCGSQpUqogSIHWyGGeVDaAyN"
    private let sender = "0QA-fMaL4JXzbdjSk7zbNxOQppYdOUkF4f4UXrIDpGYGt_lk"
    private let master = "kQDDqfCUyXigJ0xBa5m482BBZd56ebMnSIO2OLZVsqtpjF31"

    init() throws {
        let url = try #require(Bundle.allBundles.compactMap {
            $0.url(forResource: "ton-jetton-captures", withExtension: "json")
        }.first)

        captures = try JSONDecoder().decode(Captures.self, from: Data(contentsOf: url))
    }

    private func actions(_ items: [AnyJSON]) throws -> String {
        let joined = try items.map { String(data: try $0.data, encoding: .utf8) ?? "{}" }.joined(separator: ",")
        return #"{"actions":[\#(joined)],"address_book":{},"metadata":{}}"#
    }

    @Test func aTransferIsReadWithItsActionIdentityAndTheExternalHash() async throws {
        let transport = FakeTonTransport()
        transport.route("actions", try actions([captures.okAction]))
        let client = TonClient(network: .testnet, transport: transport)
        let found = try await client.jettonActions(of: TonAddress(string: recipient))
        let action = try #require(found.actions.first)

        #expect(action.amount == 1_500_000)
        #expect(action.success == true)
        #expect(action.master.hash == (try TonAddress(string: master)).hash)
        #expect(action.requestHash == "fbb1081eaf0dc878ecd4e5ffb88fd86a853c0372cef94fef94f1c017f9b55211")
        #expect(action.queryId == "6381162093002101806")
    }

    @Test func aTraceEndPrecedingTheActionEndIsUsedNotTheActionEnd() throws {
        var wire = try #require(captures.okAction.value as? [String: Any])
        wire["end_lt"] = "100"
        wire["trace_end_lt"] = "900"
        let data = try JSONSerialization.data(withJSONObject: wire)
        let action = try JSONDecoder().decode(TonClient.ActionsResponse.Action.self, from: data)
        #expect(try action.jettonAction(network: .testnet)?.lt == 900)
    }

    @Test func thePageCarriesTheProvidersCursorEvenWhenAnActionIsUnreadable() async throws {
        let unreadable = #"{"action_id":"AA==","end_lt":"1","trace_id":"t","type":"jetton_transfer","details":{}}"#
        let json = try actions([captures.okAction]).replacingOccurrences(
            of: #""actions":["#,
            with: #""next_cursor":"abc","actions":[\#(unreadable),"#
        )

        let transport = FakeTonTransport()
        transport.route("actions", json)
        let client = TonClient(network: .testnet, transport: transport)
        let page = try await client.jettonActions(of: TonAddress(string: recipient))
        #expect(page.actions.count == 1)
        #expect(page.nextCursor == "abc")

        transport.route("actions", try actions([captures.okAction]))
        #expect(try await client.jettonActions(of: TonAddress(string: recipient)).nextCursor == nil)
    }

    @Test func aSentTransferCarriesItsQueryIdForPlaceholderMatching() async throws {
        let transport = FakeTonTransport()
        transport.route("actions", try actions([captures.okAction]))
        let client = TonClient(network: .testnet, transport: transport)
        let owner = try TonAddress(string: sender)
        let sent = try #require(try await client.jettonActions(of: owner).actions.first).transaction(owner: owner)
        let key = try #require(sent.effects.first?.rawPayload.flatMap { String(data: $0, encoding: .utf8) })
        #expect(key == "query:6381162093002101806")
    }

    @Test func twoSentTransfersOfOneTraceKeepSeparateEffects() throws {
        let owner = try TonAddress(string: sender)
        let master = try TonAddress(string: master)
        let to = try TonAddress(string: recipient)

        func sent(_ id: String, query: String) -> BlockchainTransaction {
            TonJettonAction(
                actionId: id, amount: 1, lt: 9, master: master, queryId: query, receiver: to,
                requestHash: "req", sender: owner, traceId: "t"
            ).transaction(owner: owner)
        }

        // Reused and colliding query ids: only the action id tells them apart.
        let first = sent("aa01", query: "11")
        let second = sent("bb02", query: "11")
        #expect(first.identifier == second.identifier)
        #expect(first.effects.first?.index != second.effects.first?.index)

        // Ids sharing the 60-bit prefix still differ in the key.
        let long = sent("0123456789abcdef0001", query: "11")
        let longer = sent("0123456789abcdef0002", query: "11")
        #expect(long.effects.first?.index == longer.effects.first?.index)
        #expect(long.effects.first?.key != longer.effects.first?.key)
    }

    @Test func aPlaceholderEffectIsTheTokenPaymentMarkedLocal() {
        let transfer = TonJettonTransfer(amount: "10", master: "m", queryId: 5, recipient: "r", senderWallet: "w")
        let effect = transfer.placeholderEffect(sender: "s")
        #expect(effect.kind == .tokenTransfer)
        #expect(effect.assetIdentifier == "m")
        #expect(effect.amount == "10")
        #expect(effect.rawPayload.flatMap { String(data: $0, encoding: .utf8) } == "query:5|local")
    }

    @Test func aReceivedTransferIsAFullEntryWithoutABlockHeight() async throws {
        let transport = FakeTonTransport()
        transport.route("actions", try actions([captures.okAction]))
        let client = TonClient(network: .testnet, transport: transport)
        let owner = try TonAddress(string: recipient)
        let entry = try #require(try await client.jettonActions(of: owner).actions.first).transaction(owner: owner)

        #expect(entry.method == "Receive")
        #expect(entry.blockHeight == nil)
        #expect(entry.isEffectsOnly == false)
        #expect(entry.effects.first?.kind == .tokenTransfer)
        #expect(entry.effects.first?.assetIdentifier == master)
    }

    @Test func aSentTransferMergesIntoTheRequestsEntryByCarryingOnlyTheEffect() async throws {
        let transport = FakeTonTransport()
        transport.route("actions", try actions([captures.okAction]))
        let client = TonClient(network: .testnet, transport: transport)
        let owner = try TonAddress(string: sender)
        let entry = try #require(try await client.jettonActions(of: owner).actions.first).transaction(owner: owner)

        #expect(entry.isEffectsOnly == true)
        #expect(entry.identifier == "fbb1081eaf0dc878ecd4e5ffb88fd86a853c0372cef94fef94f1c017f9b55211")
    }

    /// The transfer the captured OK action performed.
    private var sent: TonJettonTransfer {
        TonJettonTransfer(
            amount: "1500000",
            master: master,
            queryId: 6_381_162_093_002_101_806,
            recipient: recipient,
            senderWallet: "0:55BD205C366AE3C726B2A708957689AA273A6EE2EC6AC93161693DFE647D5F6D"
        )
    }

    /// The OK action with some fields changed.
    private func variant(id: String, amount: String? = nil, success: Bool = true) throws -> AnyJSON {
        var wire = try #require(captures.okAction.value as? [String: Any])
        var details = try #require(wire["details"] as? [String: Any])
        details["amount"] = amount ?? details["amount"]
        wire["details"] = details
        wire["action_id"] = id
        wire["success"] = success
        return try JSONDecoder().decode(AnyJSON.self, from: JSONSerialization.data(withJSONObject: wire))
    }

    /// `firstHop` is what the transaction processing the request's first message looks like (none: not indexed).
    private func delivery(
        _ items: [AnyJSON],
        transfer: TonJettonTransfer,
        firstHop: String = #"{"transactions":[],"address_book":{}}"#
    ) async throws -> TonJettonDelivery {
        let transport = FakeTonTransport()
        transport.route("traces", Self.completeTrace)
        transport.route("actions", try actions(items))
        transport.route("transactionsByMessage", firstHop)
        return try await TonClient(network: .testnet, transport: transport)
            .jettonDelivery(ofRequest: "ab", transfer: transfer, firstHopMessage: "hop")
    }

    private static let abortedFirstHop = """
    {"transactions":[{"hash":"AAAA","lt":"1","description":{"aborted":true,
     "compute_ph":{"success":false}},"in_msg":{"hash":"AAAA"}}],"address_book":{}}
    """

    @Test func aCompleteTraceWithTheMatchingTransferIsDelivered() async throws {
        #expect(try await delivery([captures.okAction], transfer: sent) == .delivered)
    }

    @Test func aRefusalOfTheRequestsFirstHopFails() async throws {
        let result = try await delivery([], transfer: sent, firstHop: Self.abortedFirstHop)
        #expect(result == .failed)
    }

    @Test func aRestoredRequestWithoutIntentStillDetectsAFirstHopRefusal() async throws {
        let transport = FakeTonTransport()
        transport.route("transactionsByMessage", Self.abortedFirstHop)
        let client = TonClient(network: .testnet, transport: transport)
        let refused = try await client.jettonDelivery(ofRequest: nil, transfer: nil, firstHopMessage: "hop")
        #expect(refused == .failed)

        transport.route("transactionsByMessage", #"{"transactions":[],"address_book":{}}"#)
        let open = try await client.jettonDelivery(ofRequest: nil, transfer: nil, firstHopMessage: "hop")
        #expect(open == .pending)
    }

    @Test func anUnrelatedFailedCallToTheSendersJettonWalletDecidesNothing() async throws {
        // The captured failed call targets the sender's Jetton wallet, but the first hop isn't known to have failed.
        #expect(try await delivery(captures.failedActions, transfer: sent) == .pending)
    }

    @Test func aMatchingActionWithoutAnExplicitResultStaysPending() async throws {
        var wire = try #require(captures.okAction.value as? [String: Any])
        wire.removeValue(forKey: "success")
        let unclassified = try JSONDecoder().decode(AnyJSON.self, from: JSONSerialization.data(withJSONObject: wire))
        #expect(try await delivery([unclassified], transfer: sent) == .pending)
    }

    @Test func aRecipientInAnotherWorkchainIsADifferentRecipient() async throws {
        let hash = try TonAddress(string: recipient).hash.map { String(format: "%02x", $0) }.joined()
        let other = TonJettonTransfer(
            amount: sent.amount, master: sent.master, queryId: sent.queryId,
            recipient: "-1:" + hash, senderWallet: sent.senderWallet
        )

        #expect(try await delivery([captures.okAction], transfer: other) == .pending)
    }

    @Test func aFailedNotificationDecidesNothing() async throws {
        var wire = try #require(captures.okAction.value as? [String: Any])
        wire["type"] = "call_contract"
        wire["success"] = false
        wire["details"] = ["opcode": "0x7362d09c", "destination": "0:" + String(repeating: "0", count: 64)]
        let failedNotification = try JSONDecoder().decode(
            AnyJSON.self, from: JSONSerialization.data(withJSONObject: wire)
        )

        #expect(try await delivery([failedNotification], transfer: sent) == .pending)
    }

    @Test func aReusedQueryIdSettlesOnlyAgainstTheTransferWithTheSameAmountAndRecipient() async throws {
        let other = try variant(id: "other", amount: "7", success: false)
        let ours = try variant(id: "ours")
        #expect(try await delivery([other, ours], transfer: sent) == .delivered)

        let othersSucceeds = try variant(id: "other", amount: "7")
        let oursFails = try variant(id: "ours", success: false)
        #expect(try await delivery([othersSucceeds, oursFails], transfer: sent) == .failed)

        var elsewhere = sent
        elsewhere = TonJettonTransfer(
            amount: "7", master: elsewhere.master, queryId: elsewhere.queryId,
            recipient: elsewhere.recipient, senderWallet: elsewhere.senderWallet
        )

        #expect(try await delivery([captures.okAction], transfer: elsewhere) == .pending)
    }

    @Test func theMatchingActionOnALaterPageIsFound() async throws {
        let transport = FakeTonTransport()
        transport.route("traces", Self.completeTrace)
        let first = try actions([variant(id: "other", amount: "7", success: false)])
            .replacingOccurrences(of: #""actions":["#, with: #""next_cursor":"c1","actions":["#)

        transport.route("actions", sequence: [first, try actions([captures.okAction])])
        let client = TonClient(network: .testnet, transport: transport)
        #expect(try await client.jettonDelivery(ofRequest: "ab", transfer: sent, firstHopMessage: "hop") == .delivered)
    }

    @Test func aTraceThatIsStillRunningIsPending() async throws {
        let transport = FakeTonTransport()
        transport.route("traces", Self.runningTrace)
        transport.route("transactionsByMessage", #"{"transactions":[],"address_book":{}}"#)
        let client = TonClient(network: .testnet, transport: transport)
        #expect(try await client.jettonDelivery(ofRequest: "ab", transfer: sent, firstHopMessage: "hop") == .pending)

        transport.route("traces", #"{"traces":[]}"#)
        #expect(try await client.jettonDelivery(ofRequest: "ab", transfer: sent, firstHopMessage: "hop") == .pending)
    }
}
