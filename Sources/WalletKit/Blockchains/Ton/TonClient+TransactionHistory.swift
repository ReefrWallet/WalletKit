//
//  TonClient+TransactionHistory.swift
//  WalletKit
//
//  Copyright © 2026 Reefr Wallet. All rights reserved.
//

import Foundation

/// Where a message sent by a wallet ended up, independent of the wallet's own transaction.
public enum TonDeliveryStatus: Equatable, Sendable {
    /// The funds were returned to the sender.
    case bounced
    /// The recipient's transaction processed the message.
    case delivered
    /// The recipient's transaction aborted without a bounce.
    case failed
    /// No recipient transaction is indexed yet.
    case pending
}

/// The payload of an outgoing history entry: the message whose delivery is tracked apart from the entry, and
/// the recipient-side outcome once known. A stored outcome is final and survives the entry being re-imported.
public struct TonDeliveryReference: Codable, Equatable, Sendable {
    public enum Outcome: String, Codable, Sendable {
        /// Bounced or aborted at the recipient.
        case failed
        case delivered
    }

    /// The first outgoing message's hash, as toncenter reports it (base64).
    public let outMessageHash: String
    public var outcome: Outcome?

    public init(outMessageHash: String, outcome: Outcome? = nil) {
        self.outMessageHash = outMessageHash
        self.outcome = outcome
    }
}

/// Account history from the toncenter v3 indexer.
///
/// The coordinate is the account's logical time (`lt`), which strictly increases per account, so paging
/// continues from `lastLT - 1` going backward and `lastLT + 1` going forward with no gaps or duplicates when
/// new activity arrives between pages. A transaction whose incoming message is external is identified by that
/// message's TEP-467 normalized hash, the identifier ``TonClient/broadcast(transaction:signature:)`` returns,
/// so a pending send merges into one history entry.
extension TonClient {
    static let historyPageLimit: UInt32 = 50

    public func transactionHistory(
        _ owner: TonAddress,
        request: BlockchainTransactionHistoryRequest
    ) async throws -> BlockchainTransactionPage {
        let cursor = try request.cursor.map { try JSONDecoder().decode(HistoryCursor.self, from: $0) }
        let limit = min(request.limit, Self.historyPageLimit)
        var query = ["account": owner.rawString, "limit": String(limit)]

        switch request.direction {
        case .descending:
            query["sort"] = "desc"
            (cursor?.next ?? request.upperBound).map { query["end_lt"] = String($0) }
            request.lowerBound.map { query["start_lt"] = String($0) }
        case .ascending:
            query["sort"] = "asc"
            (cursor?.next ?? request.lowerBound).map { query["start_lt"] = String($0) }
            request.upperBound.map { query["end_lt"] = String($0) }
        }

        let response: HistoryResponse = try await getIndexer("transactions", query: query)
        let transactions = response.transactions.map { $0.normalized(owner: owner, book: response.addressBook) }
        let logicalTimes = response.transactions.compactMap { UInt64($0.lt) }
        let reachedBoundary = response.transactions.count < Int(limit)
        let nextCursor: Data?

        if reachedBoundary {
            nextCursor = nil
        } else if let last = logicalTimes.last {
            let next = request.direction == .descending ? last.subtractingReportingOverflow(1) : last
                .addingReportingOverflow(1)
            nextCursor = next.overflow ? nil : try JSONEncoder().encode(HistoryCursor(next: next.partialValue))
        } else {
            nextCursor = nil
        }

        return BlockchainTransactionPage(
            transactions: transactions,
            nextCursor: nextCursor,
            reachedBoundary: reachedBoundary,
            head: logicalTimes.max()
        )
    }

    /// Where the first outgoing message of the wallet transaction `normalizedHash` ended up, read from the
    /// recipient's transaction. Tracked apart from the sender's history: the recipient's transaction can be
    /// indexed after the sender's cursor has moved on.
    public func deliveryStatus(ofOutgoingMessage messageHash: String) async throws -> TonDeliveryStatus {
        guard let transaction = try await transactionsProcessing(messageHash: messageHash).first else {
            return .pending
        }

        return transaction.deliveryStatus
    }

    /// The wallet's transactions with a logical time above `lt`, oldest first.
    func indexedTransactions(
        of owner: TonAddress,
        after lt: UInt64,
        limit: UInt32
    ) async throws -> [IndexedTransaction] {
        let response: HistoryResponse = try await getIndexer(
            "transactions",
            query: ["account": owner.rawString, "limit": String(limit), "sort": "asc", "start_lt": String(lt + 1)]
        )

        return response.transactions
    }

    func transactionsProcessing(messageHash: String) async throws -> [IndexedTransaction] {
        let response: HistoryResponse = try await getIndexer(
            "transactionsByMessage",
            query: ["direction": "in", "limit": "1", "msg_hash": messageHash]
        )

        return response.transactions
    }

    private func getIndexer<Result: Decodable>(_ method: String, query: [String: String]) async throws -> Result {
        var components = URLComponents(url: network.indexerURL.appending(path: method), resolvingAgainstBaseURL: false)
        components?.queryItems = query.sorted { $0.key < $1.key }.map { URLQueryItem(name: $0.key, value: $0.value) }

        guard let url = components?.url else {
            throw BlockchainClientError.invalidResponse(reason: "invalid toncenter URL")
        }

        do {
            return try JSONDecoder().decode(Result.self, from: try await transport.get(url))
        } catch let error as DecodingError {
            throw BlockchainClientError.decodingFailed(reason: "toncenter v3: \(error)")
        }
    }
}

// MARK: - Wire types

extension TonClient {
    struct HistoryCursor: Codable {
        let next: UInt64
    }

    struct HistoryResponse: Decodable {
        let transactions: [IndexedTransaction]
        let addressBook: [String: AddressBookEntry]

        enum CodingKeys: String, CodingKey {
            case addressBook = "address_book"
            case transactions
        }

        init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            transactions = try container.decode([IndexedTransaction].self, forKey: .transactions)
            addressBook = try container.decodeIfPresent([String: AddressBookEntry].self, forKey: .addressBook) ?? [:]
        }
    }

    struct AddressBookEntry: Decodable {
        let userFriendly: String

        enum CodingKeys: String, CodingKey {
            case userFriendly = "user_friendly"
        }
    }

    struct IndexedMessage: Decodable {
        let destination: String?
        let hash: String
        let hashNorm: String?
        let source: String?
        let value: String?

        enum CodingKeys: String, CodingKey {
            case destination, hash, source, value
            case hashNorm = "hash_norm"
        }
    }

    struct IndexedDescription: Decodable {
        struct Action: Decodable {
            let success: Bool?
        }

        struct Compute: Decodable {
            let reason: String?
            let skipped: Bool?
            let success: Bool?
        }

        let aborted: Bool?
        let action: Action?
        let bounce: BounceInfo?
        let computePhase: Compute?

        enum CodingKeys: String, CodingKey {
            case aborted, action, bounce
            case computePhase = "compute_ph"
        }
    }

    struct BounceInfo: Decodable {}

    struct IndexedTransaction: Decodable {
        let description: IndexedDescription?
        let hash: String
        let inMessage: IndexedMessage?
        let lt: String
        let now: Int?
        let outMessages: [IndexedMessage]
        /// The logical time of the account's previous transaction (`0` for its first).
        let prevTransLt: String?
        let totalFees: String?

        enum CodingKeys: String, CodingKey {
            case description, hash, lt, now
            case prevTransLt = "prev_trans_lt"
            case inMessage = "in_msg"
            case outMessages = "out_msgs"
            case totalFees = "total_fees"
        }

        init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            description = try container.decodeIfPresent(IndexedDescription.self, forKey: .description)
            hash = try container.decode(String.self, forKey: .hash)
            inMessage = try container.decodeIfPresent(IndexedMessage.self, forKey: .inMessage)
            lt = try container.decode(String.self, forKey: .lt)
            now = try container.decodeIfPresent(Int.self, forKey: .now)
            outMessages = try container.decodeIfPresent([IndexedMessage].self, forKey: .outMessages) ?? []
            prevTransLt = try container.decodeIfPresent(String.self, forKey: .prevTransLt)
            totalFees = try container.decodeIfPresent(String.self, forKey: .totalFees)
        }

        /// `true` for a transaction a wallet runs for a signed request (the incoming message is external).
        var isExternalRequest: Bool {
            inMessage != nil && inMessage?.source == nil
        }

        /// The normalized hash (hex) of the signed request this transaction ran, if it ran one.
        var requestHash: String? {
            isExternalRequest ? inMessage?.hashNorm.map(Self.hex(base64:)) : nil
        }

        var deliveryStatus: TonDeliveryStatus {
            if description?.bounce != nil {
                return .bounced
            }

            // An undeployed recipient is credited with its compute phase skipped; that is a delivery.
            let skippedForNoState = description?.computePhase?.skipped == true
                && description?.computePhase?.reason == "no_state"

            if description?.aborted == true, !skippedForNoState {
                return .failed
            }

            return .delivered
        }

        func normalized(owner: TonAddress, book: [String: AddressBookEntry]) -> BlockchainTransaction {
            func friendly(_ raw: String?) -> String? {
                raw.map { book[$0]?.userFriendly ?? $0 }
            }

            let ownerRaw = owner.rawString
            let isOutgoing = isExternalRequest
            let target = isOutgoing ? outMessages.first : inMessage
            let value = target?.value
            let effects = value.map {
                [
                    BlockchainTransactionEffect(
                        index: 0,
                        kind: .nativeTransfer,
                        assetIdentifier: nil,
                        amount: $0,
                        from: friendly(isOutgoing ? ownerRaw : inMessage?.source),
                        to: friendly(isOutgoing ? target?.destination : ownerRaw)
                    )
                ]
            } ?? []

            // The request ran but sent no message: V5R1 commits `seqno` before the actions, so this is no payment.
            let sentNothing = isOutgoing && outMessages.isEmpty
            let aborted = description?.aborted == true || description?.computePhase?.success == false
            let status: BlockchainTransactionStatus = sentNothing || (isOutgoing && aborted) ? .failed : .confirmed
            let identifier = isOutgoing ? (inMessage?.hashNorm.map(Self.hex(base64:)) ?? Self.hex(base64: hash)) : Self
                .hex(base64: hash)

            return BlockchainTransaction(
                identifier: identifier,
                blockHeight: UInt64(lt),
                blockHash: Self.hex(base64: hash),
                timestamp: now.map { Date(timeIntervalSince1970: TimeInterval($0)) },
                sender: friendly(isOutgoing ? ownerRaw : inMessage?.source),
                recipient: friendly(isOutgoing ? target?.destination : ownerRaw),
                status: status,
                rawPayload: isOutgoing ? outMessages.first.flatMap {
                    try? JSONEncoder().encode(TonDeliveryReference(outMessageHash: $0.hash))
                } : nil,
                effects: effects,
                fee: totalFees,
                method: isOutgoing ? "Transfer" : "Receive"
            )
        }

        /// toncenter reports hashes as base64; Reefr identifies transactions by hex.
        static func hex(base64 text: String) -> String {
            let normalized = text.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
            guard let data = Data(base64Encoded: normalized) else {
                return text
            }

            return data.map { String(format: "%02x", $0) }.joined()
        }
    }
}
