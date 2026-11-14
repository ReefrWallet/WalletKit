//
//  TonClient+Emulation.swift
//  WalletKit
//
//  Copyright © 2026 Reefr Wallet. All rights reserved.
//

import BigInt
import Foundation

/// What a send costs, read from emulating its whole trace.
public struct TonSendQuote: Equatable, Sendable {
    /// The Gram the wallet must hold to send: what leaves it in the request, the attached value and its fees. This
    /// is what a balance check uses.
    public let upfront: BigUInt
    /// What the wallet is out once the trace has finished and refunds (a Jetton transfer's excess) came back; `nil`
    /// when the emulated trace is incomplete.
    public let net: BigUInt?
    /// The transfer would not credit the recipient. For a complete trace that is: the request aborts, or no
    /// successful Jetton transfer matches it (the sender's wallet skipped the message, or a Jetton wallet refused
    /// it). For an incomplete trace, which may simply end before the credit, only explicit evidence counts: the
    /// request or the sender's Jetton wallet aborting, or the matching transfer failing. A failed notification or
    /// excess refund after the credit never counts.
    public let expectedToFail: Bool
    /// A successful matching Jetton transfer is in the trace. With neither this nor `expectedToFail`, the emulation
    /// was inconclusive (an incomplete trace) and the quote's amounts are all there is.
    public let creditSeen: Bool

    public init(upfront: BigUInt, net: BigUInt?, expectedToFail: Bool, creditSeen: Bool = false) {
        self.upfront = upfront
        self.net = net
        self.expectedToFail = expectedToFail
        self.creditSeen = creditSeen
    }
}

public extension TonClient {
    /// Emulates `transaction`'s whole trace (the wallet's request, the Jetton wallets' hops and the refund back).
    ///
    /// The message is the exact proposed one with a zero signature and `ignore_chksig`: a validly signed message is
    /// never sent to an emulator, so signing stays local until the user approves the quote.
    func quote(_ transaction: TonUnsignedTransaction) async throws -> TonSendQuote {
        let boc = try transaction.signedMessage(signature: Data(repeating: 0, count: 64))
        let body = try JSONEncoder().encode(
            EmulationRequest(boc: boc.base64EncodedString(), ignoreChksig: true, withActions: true)
        )

        let data = try await transport.post(network.emulationURL.appending(path: "emulateTrace"), body: body)
        let trace: EmulatedTrace

        do {
            trace = try JSONDecoder().decode(EmulatedTrace.self, from: data)
        } catch {
            throw BlockchainClientError.decodingFailed(reason: "toncenter emulation: \(error)")
        }

        return try Self.quote(of: trace, sender: TonAddress(string: transaction.sender), transfer: transaction.jetton)
    }
}

extension TonClient {
    struct EmulationRequest: Encodable {
        let boc: String
        let ignoreChksig: Bool
        let withActions: Bool

        enum CodingKeys: String, CodingKey {
            case boc
            case ignoreChksig = "ignore_chksig"
            case withActions = "with_actions"
        }
    }

    /// The message a transaction ran, as far as matching a hop to a transfer needs.
    struct EmulatedInMessage: Decodable {
        let opcode: String?
        let queryId: String?
        let source: String?

        enum CodingKeys: String, CodingKey {
            case opcode, source
            case messageContent = "message_content"
        }

        enum ContentKeys: String, CodingKey {
            case decoded
        }

        enum DecodedKeys: String, CodingKey {
            case queryId = "query_id"
        }

        init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            opcode = try container.decodeIfPresent(String.self, forKey: .opcode)
            source = try container.decodeIfPresent(String.self, forKey: .source)

            let content = try? container.nestedContainer(keyedBy: ContentKeys.self, forKey: .messageContent)
            let decoded = try? content?.nestedContainer(keyedBy: DecodedKeys.self, forKey: .decoded)
            queryId = (try? decoded?.decodeIfPresent(String.self, forKey: .queryId)) ?? nil
        }
    }

    struct EmulatedTrace: Decodable {
        struct State: Decodable {
            let balance: String?
        }

        struct Description: Decodable {
            let aborted: Bool?
        }

        struct Action: Decodable {
            let details: ActionDetails?
            let success: Bool?
            let type: String

            init(from decoder: any Decoder) throws {
                let container = try decoder.container(keyedBy: CodingKeys.self)
                details = try? container.decodeIfPresent(ActionDetails.self, forKey: .details)
                success = try container.decodeIfPresent(Bool.self, forKey: .success)
                type = try container.decode(String.self, forKey: .type)
            }

            enum CodingKeys: String, CodingKey {
                case details, success, type
            }
        }

        struct Transaction: Decodable {
            let account: String
            let accountStateAfter: State?
            let accountStateBefore: State?
            let description: Description?
            let inMessage: EmulatedInMessage?
            let lt: String

            enum CodingKeys: String, CodingKey {
                case account, description, lt
                case inMessage = "in_msg"
                case accountStateAfter = "account_state_after"
                case accountStateBefore = "account_state_before"
            }
        }

        /// A transaction of the trace tree with those it triggered.
        struct Node: Decodable {
            let children: [Node]
            let txHash: String

            enum CodingKeys: String, CodingKey {
                case children
                case txHash = "tx_hash"
            }

            init(from decoder: any Decoder) throws {
                let container = try decoder.container(keyedBy: CodingKeys.self)
                // toncenter emits `null` for a transaction whose outgoing message has no child transaction (yet).
                children = try container.decodeIfPresent([Node].self, forKey: .children) ?? []
                txHash = try container.decode(String.self, forKey: .txHash)
            }
        }

        let actions: [Action]
        let isIncomplete: Bool
        let trace: Node?
        let transactions: [String: Transaction]

        enum CodingKeys: String, CodingKey {
            case actions, trace, transactions
            case isIncomplete = "is_incomplete"
        }
    }

    /// The wallet's balance across its own transactions: the first is the request, the last may be a refund.
    static func quote(
        of trace: EmulatedTrace,
        sender: TonAddress,
        transfer: TonJettonTransfer?
    ) throws -> TonSendQuote {
        func isAccount(_ raw: String, _ address: TonAddress) -> Bool {
            (try? TonAddress(string: raw)).map { $0.workchain == address.workchain && $0.hash == address.hash } ?? false
        }

        let own = trace.transactions.values
            .filter { isAccount($0.account, sender) }
            .compactMap { transaction in UInt64(transaction.lt).map { ($0, transaction) } }
            .sorted { $0.0 < $1.0 }
            .map(\.1)

        guard let request = own.first, let last = own.last,
              let before = request.accountStateBefore?.balance.flatMap({ BigUInt($0) }),
              let afterRequest = request.accountStateAfter?.balance.flatMap({ BigUInt($0) }),
              let afterTrace = last.accountStateAfter?.balance.flatMap({ BigUInt($0) }),
              before >= afterRequest
        else {
            throw BlockchainClientError.invalidResponse(reason: "the emulated trace has no readable wallet request")
        }

        var failed = request.description?.aborted == true
        var seen = false

        if let transfer {
            let outcome = Self.creditOutcome(of: transfer, in: trace)
            seen = outcome == true
            // The sender's Jetton wallet is the request's own child. Other transactions at its address are
            // later traffic (a notification the recipient sends there) and say nothing about this transfer.
            let senderHop = (try? TonAddress(string: transfer.senderWallet)).flatMap {
                Self.child(of: trace.trace, at: $0, in: trace)
            }

            let walletRefused = senderHop.flatMap { trace.transactions[$0.txHash] }?.description?.aborted == true

            failed = failed || walletRefused || outcome == false || (!trace.isIncomplete && outcome == nil)
        }

        return TonSendQuote(
            upfront: before - afterRequest,
            net: trace.isIncomplete || before < afterTrace ? nil : before - afterTrace,
            expectedToFail: failed,
            creditSeen: seen
        )
    }

    /// The result of the Jetton transfer of exactly `transfer` (master, recipient, amount, `query_id`) in `trace`:
    /// `nil` if it is not there or not shown to reach the recipient.
    ///
    /// A matching action can be a sender-side fallback the classifier emits when it saw no internal transfer; it names
    /// no recipient Jetton wallet. Success counts only with that wallet named and its transaction on the transfer's own
    /// path (request, sender's Jetton wallet, recipient's Jetton wallet) present and not aborted: that is the credit.
    private static func creditOutcome(of transfer: TonJettonTransfer, in trace: EmulatedTrace) -> Bool? {
        func sameAddress(_ raw: String?, _ expected: String) -> Bool {
            guard let raw, let lhs = try? TonAddress(string: raw), let rhs = try? TonAddress(string: expected) else {
                return false
            }

            return lhs.workchain == rhs.workchain && lhs.hash == rhs.hash
        }

        let matching = trace.actions.filter { action in
            action.type == "jetton_transfer"
                && sameAddress(action.details?.asset, transfer.master)
                && sameAddress(action.details?.receiver, transfer.recipient)
                && action.details?.amount == transfer.amount
                && action.details?.queryId == String(transfer.queryId)
        }

        if matching.contains(where: { $0.success == false }) {
            return false
        }

        for action in matching where action.success == true {
            guard let wallet = action.details?.receiverJettonWallet else {
                continue
            }

            // The recipient's Jetton wallet is the sender wallet's child: the `internal_transfer` that carried the tokens.
            guard let receiver = try? TonAddress(string: wallet),
                  let senderWallet = try? TonAddress(string: transfer.senderWallet),
                  let senderHop = child(of: trace.trace, at: senderWallet, in: trace),
                  let hop = child(of: senderHop, at: receiver, in: trace, matching: { transaction in
                      // The `internal_transfer` of this transfer, not another message the sender's wallet sent there.
                      transaction.inMessage?.opcode == TonJetton.internalTransferOpcodeText
                          && transaction.inMessage?.queryId == String(transfer.queryId)
                          && sameAddress(transaction.inMessage?.source, transfer.senderWallet)
                  }),
                  let transaction = trace.transactions[hop.txHash]
            else {
                continue
            }

            return transaction.description?.aborted == true ? false : true
        }

        return nil
    }

    /// The first child of `node` whose transaction ran at `address` and passes `isHop`.
    private static func child(
        of node: EmulatedTrace.Node?,
        at address: TonAddress,
        in trace: EmulatedTrace,
        matching isHop: (EmulatedTrace.Transaction) -> Bool = { _ in true }
    ) -> EmulatedTrace.Node? {
        node?.children.first { child in
            guard let transaction = trace.transactions[child.txHash],
                  let account = try? TonAddress(string: transaction.account)
            else {
                return false
            }

            return account.workchain == address.workchain && account.hash == address.hash && isHop(transaction)
        }
    }
}
