//
//  TonClient+JettonHistory.swift
//  WalletKit
//
//  Copyright © 2026 Reefr Wallet. All rights reserved.
//

import BigInt
import Foundation

/// One Jetton transfer from the toncenter v3 actions API.
///
/// A recipient's Jetton wallet can be credited without a transaction on the recipient's owner wallet, so these are
/// read apart from the owner wallet's history and carry their own identity: the action id.
public struct TonJettonAction: Equatable, Sendable {
    /// Stable across polls; several transfers in one trace stay distinct.
    public let actionId: String
    public let amount: BigUInt
    public let comment: String?
    public let finality: String?
    /// The logical time its trace ended at (`trace_end_lt`), not the owner wallet's. toncenter's `start_lt` and
    /// `end_lt` filters compare against it, so it is the coordinate to scan by.
    public let lt: UInt64
    public let master: TonAddress
    public let queryId: String?
    public let receiver: TonAddress
    /// The normalized hash (hex) of the external request that started the trace, if one did.
    public let requestHash: String?
    public let sender: TonAddress
    public let success: Bool
    public let timestamp: Date?
    public let traceId: String

    public init(
        actionId: String,
        amount: BigUInt,
        comment: String? = nil,
        finality: String? = nil,
        lt: UInt64,
        master: TonAddress,
        queryId: String? = nil,
        receiver: TonAddress,
        requestHash: String? = nil,
        sender: TonAddress,
        success: Bool = true,
        timestamp: Date? = nil,
        traceId: String
    ) {
        self.actionId = actionId
        self.amount = amount
        self.comment = comment
        self.finality = finality
        self.lt = lt
        self.master = master
        self.queryId = queryId
        self.receiver = receiver
        self.requestHash = requestHash
        self.sender = sender
        self.success = success
        self.timestamp = timestamp
        self.traceId = traceId
    }
}

/// One page of Jetton transfers. Paging ends when the provider sends no cursor, however many actions were readable.
public struct TonJettonPage: Equatable, Sendable {
    public let actions: [TonJettonAction]
    /// Pass back to read the next page; `nil` on the last one.
    public let nextCursor: String?

    public init(actions: [TonJettonAction], nextCursor: String? = nil) {
        self.actions = actions
        self.nextCursor = nextCursor
    }
}

/// Where a Jetton transfer we sent ended up, read from its trace.
public enum TonJettonDelivery: Equatable, Sendable {
    /// The trace is incomplete, or its actions are not classified yet. Nothing is decided.
    case pending
    case delivered
    /// A step of the trace failed, so the tokens were not credited (or were returned).
    case failed
}

public extension TonClient {
    /// The Jetton transfers `owner` took part in, as sender or receiver.
    ///
    /// The bounds compare with ``TonJettonAction/lt``. Callers re-read an overlapping range and deduplicate by
    /// ``TonJettonAction/actionId``. Follow ``TonJettonPage/nextCursor`` with the same bounds: fix `endLt` for a scan
    /// in progress so newer actions don't shift the pages.
    func jettonActions(
        of owner: TonAddress,
        ascending: Bool = false,
        startLt: UInt64? = nil,
        endLt: UInt64? = nil,
        limit: Int = 50,
        cursor: String? = nil
    ) async throws -> TonJettonPage {
        var query = [
            "account": owner.rawString,
            "action_type": "jetton_transfer",
            "limit": String(limit),
            "sort": ascending ? "asc" : "desc"
        ]

        query["start_lt"] = startLt.map(String.init)
        query["end_lt"] = endLt.map(String.init)
        query["cursor"] = cursor
        let response: ActionsResponse = try await getIndexerPage("actions", query: query)
        // An unreadable action is skipped; it never ends the scan.
        let actions = try response.actions.compactMap { try $0.jettonAction(network: network) }
        return TonJettonPage(actions: actions, nextCursor: response.nextCursor)
    }

    /// Whether the Jetton transfer submitted as the request with normalized hash `request` has credited its
    /// recipient. With `transfer` the action must match its master and `query_id`; without it any successful Jetton
    /// transfer in the trace counts. Judged by the whole trace: a failure anywhere is a failure, and a trace that is
    /// still running or not yet classified is pending.
    func jettonDelivery(
        ofRequest request: String,
        transfer: TonJettonTransfer? = nil
    ) async throws -> TonJettonDelivery {
        let traces: TracesResponse = try await getIndexerPage("traces", query: ["msg_hash": request, "limit": "1"])

        guard let trace = traces.traces.first, !trace.isIncomplete, trace.traceInfo.traceState == "complete" else {
            return .pending
        }

        let response: ActionsResponse = try await getIndexerPage(
            "actions",
            query: ["trace_id": trace.traceId, "limit": "50"]
        )

        let masterHash = try transfer.map { try makeAddress($0.master).hash }

        for action in response.actions where action.type == "jetton_transfer" {
            guard let parsed = try action.jettonAction(network: network),
                  masterHash == nil || parsed.master.hash == masterHash,
                  transfer == nil || parsed.queryId == transfer.map({ String($0.queryId) })
            else {
                continue
            }

            return parsed.success ? .delivered : .failed
        }

        // The transfer was refused before it became a Jetton transfer (for example, more than the balance).
        return response.actions.contains { $0.success == false } ? .failed : .pending
    }
}

public extension TonJettonAction {
    /// The history entry of this transfer for `owner`.
    ///
    /// An entry the owner sent shares its identifier with the request's own history entry and carries only the
    /// token effect, so the two merge. A received one is a full entry; it has no block height, which would
    /// otherwise disturb the owner wallet's own sync position.
    func transaction(owner: TonAddress) -> BlockchainTransaction {
        let isOutgoing = sender.hash == owner.hash
        let identifier = requestHash ?? actionId
        // The full action id is the durable identity (the index is only its 60-bit prefix, for ordering), so actions
        // sharing a `query_id` stay apart. The payload
        // lets a send placeholder, which only knows the `query_id`, be replaced by its action.
        let effect = BlockchainTransactionEffect(
            index: Self.effectIndex(actionId),
            kind: .tokenTransfer,
            assetIdentifier: master.string,
            amount: String(amount),
            from: sender.string,
            to: receiver.string,
            rawPayload: queryId.map { Data(Self.queryKey($0).utf8) },
            key: actionId
        )

        return BlockchainTransaction(
            identifier: identifier,
            timestamp: timestamp,
            sender: sender.string,
            recipient: receiver.string,
            status: success ? .confirmed : .failed,
            effects: [effect],
            method: isOutgoing ? "Transfer" : "Receive",
            isEffectsOnly: isOutgoing
        )
    }

    /// The effect payload that ties a transfer to its `query_id`; a send placeholder appends ``localSuffix``.
    static func queryKey(_ queryId: String) -> String {
        "query:\(queryId)"
    }

    /// Marks an effect written locally before its action is known.
    static let localSuffix = "|local"

    /// A stable index for the effect, from the action id.
    private static func effectIndex(_ actionId: String) -> UInt64 {
        UInt64(actionId.prefix(15), radix: 16) ?? 0
    }
}

// MARK: - Wire types

extension TonClient {
    struct ActionDetails: Decodable {
        let amount: String?
        let asset: String?
        let comment: String?
        let queryId: String?
        let receiver: String?
        let sender: String?

        enum CodingKeys: String, CodingKey {
            case amount, asset, comment, receiver, sender
            case queryId = "query_id"
        }
    }

    struct TraceInfo: Decodable {
        let traceState: String

        enum CodingKeys: String, CodingKey {
            case traceState = "trace_state"
        }
    }

    struct ActionsResponse: Decodable {
        struct Action: Decodable {
            let actionId: String
            let details: ActionDetails?
            let finality: String?
            let endLt: String
            let traceEndLt: String?
            let startUtime: Int?
            let success: Bool?
            let traceExternalHashNorm: String?
            let traceId: String
            let type: String

            enum CodingKeys: String, CodingKey {
                case details, finality, success, type
                case actionId = "action_id"
                case endLt = "end_lt"
                case traceEndLt = "trace_end_lt"
                case startUtime = "start_utime"
                case traceExternalHashNorm = "trace_external_hash_norm"
                case traceId = "trace_id"
            }

            init(from decoder: any Decoder) throws {
                let container = try decoder.container(keyedBy: CodingKeys.self)
                actionId = try container.decode(String.self, forKey: .actionId)
                details = try? container.decodeIfPresent(ActionDetails.self, forKey: .details)
                finality = try container.decodeIfPresent(String.self, forKey: .finality)
                endLt = try container.decode(String.self, forKey: .endLt)
                traceEndLt = try container.decodeIfPresent(String.self, forKey: .traceEndLt)
                startUtime = try container.decodeIfPresent(Int.self, forKey: .startUtime)
                success = try container.decodeIfPresent(Bool.self, forKey: .success)
                traceExternalHashNorm = try container.decodeIfPresent(String.self, forKey: .traceExternalHashNorm)
                traceId = try container.decode(String.self, forKey: .traceId)
                type = try container.decode(String.self, forKey: .type)
            }

            /// `nil` for an action that is not a readable Jetton transfer.
            func jettonAction(network: TonNetwork) throws -> TonJettonAction? {
                guard type == "jetton_transfer", let details, let asset = details.asset, let sender = details.sender,
                      let receiver = details.receiver, let amount = details.amount.flatMap({ BigUInt($0) }),
                      let lt = UInt64(traceEndLt ?? endLt)
                else {
                    return nil
                }

                func canonical(_ raw: String, isMaster: Bool = false) throws -> TonAddress {
                    let address = try TonAddress(string: raw)
                    return try TonAddress(
                        workchain: address.workchain,
                        hash: address.hash,
                        isBounceable: isMaster ? true : nil,
                        isTestOnly: network == .testnet
                    )
                }

                return TonJettonAction(
                    actionId: TonClient.IndexedTransaction.hex(base64: actionId),
                    amount: amount,
                    comment: details.comment,
                    finality: finality,
                    lt: lt,
                    master: try canonical(asset, isMaster: true),
                    queryId: details.queryId,
                    receiver: try canonical(receiver),
                    requestHash: traceExternalHashNorm.map(TonClient.IndexedTransaction.hex(base64:)),
                    sender: try canonical(sender),
                    success: success ?? false,
                    timestamp: startUtime.map { Date(timeIntervalSince1970: TimeInterval($0)) },
                    traceId: traceId
                )
            }
        }

        let actions: [Action]
        let nextCursor: String?

        enum CodingKeys: String, CodingKey {
            case actions
            case nextCursor = "next_cursor"
        }
    }

    struct TracesResponse: Decodable {
        struct Trace: Decodable {
            let isIncomplete: Bool
            let traceId: String
            let traceInfo: TraceInfo

            enum CodingKeys: String, CodingKey {
                case isIncomplete = "is_incomplete"
                case traceId = "trace_id"
                case traceInfo = "trace_info"
            }
        }

        let traces: [Trace]
    }
}
