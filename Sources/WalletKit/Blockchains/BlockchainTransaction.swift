//
//  BlockchainTransaction.swift
//  WalletKit
//

import Foundation

/// The persistence-neutral lifecycle of a transaction observed by a chain client.
public enum BlockchainTransactionStatus: String, Codable, Sendable {
    case broadcast
    case unconfirmed
    case confirmed
    case reverted
    case failed
}

/// A chain-normalised effect belonging to a transaction.
///
/// Amounts remain decimal strings because different chains use integer widths
/// that do not fit in a shared fixed-width Swift integer.
public struct BlockchainTransactionEffect: Codable, Hashable, Sendable {
    public enum Kind: String, Codable, Sendable {
        case nativeTransfer
        case tokenTransfer
        case tokenApproval
        case balanceChange
        case unknown
    }

    public let index: UInt64
    public let kind: Kind
    public let assetIdentifier: String?
    public let amount: String?
    public let from: String?
    public let to: String?
    public let rawPayload: Data?

    public init(
        index: UInt64,
        kind: Kind,
        assetIdentifier: String? = nil,
        amount: String? = nil,
        from: String? = nil,
        to: String? = nil,
        rawPayload: Data? = nil
    ) {
        self.index = index
        self.kind = kind
        self.assetIdentifier = assetIdentifier
        self.amount = amount
        self.from = from
        self.to = to
        self.rawPayload = rawPayload
    }
}

/// A normalised transaction returned by a blockchain node.
///
/// `identifier` is the chain hash/digest. It is intentionally opaque: EVM
/// hashes, Sui digests, and future chain identifiers have different encodings.
public struct BlockchainTransaction: Codable, Hashable, Sendable {
    public let identifier: String
    public let blockHeight: UInt64?
    public let blockHash: String?
    public let timestamp: Date?
    public let transactionIndex: UInt64?
    public let sender: String?
    public let recipient: String?
    public let status: BlockchainTransactionStatus
    public let rawPayload: Data?
    public let effects: [BlockchainTransactionEffect]

    public init(
        identifier: String,
        blockHeight: UInt64? = nil,
        blockHash: String? = nil,
        timestamp: Date? = nil,
        transactionIndex: UInt64? = nil,
        sender: String? = nil,
        recipient: String? = nil,
        status: BlockchainTransactionStatus,
        rawPayload: Data? = nil,
        effects: [BlockchainTransactionEffect] = []
    ) {
        self.identifier = identifier
        self.blockHeight = blockHeight
        self.blockHash = blockHash
        self.timestamp = timestamp
        self.transactionIndex = transactionIndex
        self.sender = sender
        self.recipient = recipient
        self.status = status
        self.rawPayload = rawPayload
        self.effects = effects
    }
}

public enum BlockchainTransactionScanDirection: String, Codable, Sendable {
    case ascending
    case descending
}

/// A page cursor is opaque to the application. It lets each chain retain the
/// exact node-specific resume position required for a safe replay.
public struct BlockchainTransactionPage: Sendable {
    public let transactions: [BlockchainTransaction]
    public let nextCursor: Data?
    public let reachedBoundary: Bool
    public let head: UInt64?

    public init(
        transactions: [BlockchainTransaction],
        nextCursor: Data?,
        reachedBoundary: Bool,
        head: UInt64? = nil
    ) {
        self.transactions = transactions
        self.nextCursor = nextCursor
        self.reachedBoundary = reachedBoundary
        self.head = head
    }
}

/// A newly observed chain head used to drive forward catch-up.
public struct BlockchainTransactionHead: Sendable {
    public let height: UInt64
    public let hash: String?
    public let parentHash: String?

    public init(height: UInt64, hash: String? = nil, parentHash: String? = nil) {
        self.height = height
        self.hash = hash
        self.parentHash = parentHash
    }
}

/// A bounded history request. `lowerBound` and `upperBound` use the chain's
/// numeric block/checkpoint coordinate when it has one; the opaque cursor is
/// authoritative for subsequent pages.
public struct BlockchainTransactionHistoryRequest: Sendable {
    /// Asset identifiers (token contracts) already known for the account. Clients whose node
    /// rejects unscoped token-event queries narrow them to these instead of dropping them.
    public let assetHints: [String]
    public let cursor: Data?
    public let direction: BlockchainTransactionScanDirection
    public let lowerBound: UInt64?
    public let upperBound: UInt64?
    public let limit: UInt32

    public init(
        cursor: Data? = nil,
        direction: BlockchainTransactionScanDirection,
        lowerBound: UInt64? = nil,
        upperBound: UInt64? = nil,
        limit: UInt32 = 100,
        assetHints: [String] = []
    ) {
        self.assetHints = assetHints
        self.cursor = cursor
        self.direction = direction
        self.lowerBound = lowerBound
        self.upperBound = upperBound
        self.limit = limit
    }
}
