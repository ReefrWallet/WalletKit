import BigInt
import Foundation
import Testing
@testable import WalletKit

/// Reads quotes from traces captured from the TON testnet (ton-emulation-captures.json): a Jetton transfer to an
/// owner without a Jetton wallet, and to one with a wallet.
struct TonEmulationTests {
    private let owner = "0:3E7CC68BE095F36DD8D293BCDB371390A6961D394905E1FE145EB203A46606B7"
    private let senderWallet = "0:55BD205C366AE3C726B2A708957689AA273A6EE2EC6AC93161693DFE647D5F6D"

    private func trace(
        _ name: String,
        edit: (inout [String: Any]) -> Void = { _ in }
    ) throws -> TonClient.EmulatedTrace {
        let url = try #require(Bundle.allBundles.compactMap {
            $0.url(forResource: "ton-emulation-captures", withExtension: "json")
        }.first)

        let all = try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        var capture = try #require(all[name] as? [String: Any])
        edit(&capture)
        return try JSONDecoder().decode(
            TonClient.EmulatedTrace.self,
            from: JSONSerialization.data(withJSONObject: capture)
        )
    }

    private let master = "0:C3A9F094C978A0274C416B99B8F3604165DE7A79B3274883B638B655B2AB698C"

    /// The transfer each capture emulated.
    private func transfer(
        recipient: String = "0:4242424242424242424242424242424242424242424242424242424242424242",
        amount: String = "100",
        queryId: UInt64 = 7_590_783_841_519_935_462
    ) -> TonJettonTransfer {
        TonJettonTransfer(
            amount: amount, master: master, queryId: queryId, recipient: recipient, senderWallet: senderWallet
        )
    }

    private func quote(_ trace: TonClient.EmulatedTrace, _ transfer: TonJettonTransfer?) throws -> TonSendQuote {
        try TonClient.quote(of: trace, sender: TonAddress(string: owner), transfer: transfer)
    }

    @Test func theUpfrontAmountIsWhatTheRequestTakesAndTheNetCostWhatIsLeftAfterTheRefund() throws {
        let fresh = try quote(trace("fresh"), transfer())

        // 50 000 000 attached + 538 077 fees + 78 046 forwarding; 22 964 990 comes back as excess.
        #expect(fresh.upfront == 50_616_123)
        #expect(fresh.net == 27_703_001)
        #expect(!fresh.expectedToFail)
        #expect(fresh.creditSeen)

        // An owner that already has a Jetton wallet gets more back, since no wallet is deployed.
        let existing = try quote(
            trace("existing"),
            transfer(
                recipient: "0:E5E234E7AE775780B7CCE97DEC73E9564535F13E8003F4AEB837C0F88AE6D570",
                queryId: 1_838_836_526_895_181_838
            )
        )

        #expect(existing.upfront == fresh.upfront)
        #expect(existing.net == 17_703_001)
        #expect(!existing.expectedToFail)
    }

    @Test func anIncompleteTraceHasNoNetCost() throws {
        let incomplete = try trace("fresh") { $0["is_incomplete"] = true }
        let result = try quote(incomplete, transfer())
        #expect(result.net == nil)
        #expect(result.upfront == 50_616_123)
    }

    @Test func anIncompleteTraceWithoutTheCreditYetIsInconclusiveNotRefused() throws {
        // The emulation stopped at its depth limit before the credit became visible.
        let cutOff = try trace("fresh") { capture in
            capture["is_incomplete"] = true
            capture["actions"] = [] as [Any]
        }

        let result = try quote(cutOff, transfer())
        #expect(!result.expectedToFail)
        #expect(!result.creditSeen)
        #expect(result.net == nil)
        #expect(result.upfront == 50_616_123)
    }

    @Test func anIncompleteTraceStillBlocksAnExplicitRefusal() throws {
        let failedCredit = try trace("fresh") { capture in
            capture["is_incomplete"] = true
            var actions = capture["actions"] as? [[String: Any]] ?? []
            actions[0]["success"] = false
            capture["actions"] = actions
        }

        #expect(try quote(failedCredit, transfer()).expectedToFail)

        let walletRefused = try trace("fresh") { capture in
            capture["is_incomplete"] = true
            capture["actions"] = [] as [Any]
            var transactions = capture["transactions"] as? [String: [String: Any]] ?? [:]

            for (hash, transaction) in transactions where (transaction["account"] as? String) == senderWallet {
                var edited = transaction
                edited["description"] = ["aborted": true]
                transactions[hash] = edited
            }

            capture["transactions"] = transactions
        }

        #expect(try quote(walletRefused, transfer()).expectedToFail)
    }

    @Test func aTransferTheWalletSkippedWithoutAbortingWouldFail() throws {
        // V5 commits the seqno and sends nothing: every transaction succeeds, but no transfer happens.
        let skipped = try trace("fresh") { $0["actions"] = [] as [Any] }
        #expect(try quote(skipped, transfer()).expectedToFail)
    }

    @Test func aRecipientsJettonWalletRefusingTheCreditWouldFail() throws {
        // Both sender-side transactions succeed; the credit is the part that failed.
        let refused = try trace("fresh") { capture in
            var actions = capture["actions"] as? [[String: Any]] ?? []
            actions[0]["success"] = false
            capture["actions"] = actions
        }

        #expect(try quote(refused, transfer()).expectedToFail)
    }

    @Test func aSenderSideFallbackActionIsNotTheRecipientsCredit() throws {
        // The classifier saw no internal transfer: the action succeeds but names no recipient Jetton wallet.
        let senderOnly = try trace("fresh") { capture in
            var actions = capture["actions"] as? [[String: Any]] ?? []
            var details = actions[0]["details"] as? [String: Any] ?? [:]
            details["receiver_jetton_wallet"] = NSNull()
            actions[0]["details"] = details
            capture["actions"] = actions
        }

        let result = try quote(senderOnly, transfer())
        #expect(result.expectedToFail)
        #expect(!result.creditSeen)

        // Cut off before the recipient hop, it is only inconclusive.
        let cutOff = try trace("fresh") { capture in
            capture["is_incomplete"] = true
            var actions = capture["actions"] as? [[String: Any]] ?? []
            var details = actions[0]["details"] as? [String: Any] ?? [:]
            details["receiver_jetton_wallet"] = NSNull()
            actions[0]["details"] = details
            capture["actions"] = actions
        }

        #expect(try !quote(cutOff, transfer()).expectedToFail)
    }

    @Test func anAbortedRecipientHopIsARefusalEvenWithASuccessfulAction() throws {
        let receiverWallet = "0:C189FC4AB5903C60E7381B33333ED4D50F6CBB136CD55956D72D84F7BC0D387B"
        let aborted = try trace("fresh") { capture in
            var transactions = capture["transactions"] as? [String: [String: Any]] ?? [:]

            for (hash, transaction) in transactions where (transaction["account"] as? String) == receiverWallet {
                var edited = transaction
                edited["description"] = ["aborted": true]
                transactions[hash] = edited
            }

            capture["transactions"] = transactions
        }

        #expect(try quote(aborted, transfer()).expectedToFail)
    }

    @Test func anAbortAtASenderWalletAddressOffThePathIsNotARefusal() throws {
        // The recipient's Jetton wallet credits, then notifies the sender's Jetton wallet, which rejects it: the
        // transfer's own path is intact.
        let receiverWallet = "0:C189FC4AB5903C60E7381B33333ED4D50F6CBB136CD55956D72D84F7BC0D387B"
        let later = try trace("fresh") { capture in
            var transactions = capture["transactions"] as? [String: [String: Any]] ?? [:]
            transactions["late"] = [
                "account": senderWallet, "lt": "999999999999999999", "description": ["aborted": true],
                "account_state_before": ["balance": "1"], "account_state_after": ["balance": "1"]
            ]

            capture["transactions"] = transactions

            func attach(_ node: [String: Any]) -> [String: Any] {
                var edited = node
                var children = (node["children"] as? [[String: Any]] ?? []).map(attach)

                let account = (node["tx_hash"] as? String).flatMap { transactions[$0]?["account"] as? String }

                if account == receiverWallet {
                    children.append(["tx_hash": "late", "children": [] as [Any]])
                }

                edited["children"] = children
                return edited
            }

            capture["trace"] = attach(capture["trace"] as? [String: Any] ?? [:])
        }

        let result = try quote(later, transfer())
        #expect(!result.expectedToFail)
        #expect(result.creditSeen)
    }

    @Test func aNullChildListIsAnEmptyOneNotADecodingFailure() throws {
        // toncenter emits `null` for a transaction whose message produced no child transaction (yet).
        let nulled = try trace("fresh") { capture in
            func blank(_ node: [String: Any]) -> [String: Any] {
                var edited = node
                let children = (node["children"] as? [[String: Any]] ?? []).map(blank)
                edited["children"] = children.isEmpty ? NSNull() : children
                return edited
            }

            capture["trace"] = blank(capture["trace"] as? [String: Any] ?? [:])
        }

        // The tree is intact down to the leaves, so the result is the same.
        let result = try quote(nulled, transfer())
        #expect(result.creditSeen)

        // A refusal further up the tree is still found when the tree below it is cut off.
        let refused = try trace("fresh") { capture in
            capture["actions"] = [] as [Any]
            var root = capture["trace"] as? [String: Any] ?? [:]
            var senderHop = (root["children"] as? [[String: Any]] ?? [])[0]
            senderHop["children"] = NSNull()
            root["children"] = [senderHop]
            capture["trace"] = root
            var transactions = capture["transactions"] as? [String: [String: Any]] ?? [:]

            if let hash = senderHop["tx_hash"] as? String, var edited = transactions[hash] {
                edited["description"] = ["aborted": true]
                transactions[hash] = edited
            }

            capture["transactions"] = transactions
        }

        #expect(try quote(refused, transfer()).expectedToFail)
    }

    @Test func aSiblingMessageToTheRecipientsWalletIsNotTheTransfersHop() throws {
        let receiverWallet = "0:C189FC4AB5903C60E7381B33333ED4D50F6CBB136CD55956D72D84F7BC0D387B"
        let crowded = try trace("fresh") { capture in
            var transactions = capture["transactions"] as? [String: [String: Any]] ?? [:]
            var siblings: [[String: Any]] = []

            // Same address, aborted, but another message (a different opcode, then another query_id).
            for (index, hop) in [("0x0f8a7ea5", "1"), ("0x178d4519", "999")].enumerated() {
                transactions["sibling\(index)"] = [
                    "account": receiverWallet, "lt": "99999999999999\(index)", "description": ["aborted": true],
                    "in_msg": [
                        "source": senderWallet, "opcode": hop.0,
                        "message_content": ["decoded": ["query_id": hop.1]]
                    ],
                    "account_state_before": ["balance": "1"], "account_state_after": ["balance": "1"]
                ]

                siblings.append(["tx_hash": "sibling\(index)", "children": [] as [Any]])
            }

            capture["transactions"] = transactions

            func attach(_ node: [String: Any]) -> [String: Any] {
                var edited = node
                var children = (node["children"] as? [[String: Any]] ?? []).map(attach)
                let account = (node["tx_hash"] as? String).flatMap { transactions[$0]?["account"] as? String }

                if account == senderWallet {
                    children.insert(contentsOf: siblings, at: 0)
                }

                edited["children"] = children
                return edited
            }

            capture["trace"] = attach(capture["trace"] as? [String: Any] ?? [:])
        }

        let result = try quote(crowded, transfer())
        #expect(!result.expectedToFail)
        #expect(result.creditSeen)
    }

    @Test func aFailedNotificationAfterASuccessfulCreditDoesNotCount() throws {
        let noisy = try trace("fresh") { capture in
            var actions = capture["actions"] as? [[String: Any]] ?? []
            actions.append(["type": "call_contract", "success": false, "details": ["opcode": "0x7362d09c"]])
            capture["actions"] = actions
        }

        #expect(try !quote(noisy, transfer()).expectedToFail)
    }

    @Test func aCreditOfAnotherAmountOrToAnotherRecipientIsNotThisTransfer() throws {
        #expect(try quote(trace("fresh"), transfer(amount: "101")).expectedToFail)
        let other = "0:E5E234E7AE775780B7CCE97DEC73E9564535F13E8003F4AEB837C0F88AE6D570"
        #expect(try quote(trace("fresh"), transfer(recipient: other)).expectedToFail)
    }

    @Test func aTraceWithoutTheWalletsRequestIsRefused() throws {
        let stranger = try TonAddress(workchain: 0, hash: Data(repeating: 1, count: 32))
        #expect(throws: BlockchainClientError.self) {
            _ = try TonClient.quote(of: trace("fresh"), sender: stranger, transfer: nil)
        }
    }
}
