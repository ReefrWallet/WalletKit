//
//  AptosClient+TransactionHistory.swift
//  WalletKit
//
//  Copyright © 2026 Reefr Wallet. All rights reserved.
//

import Foundation

/// Indexer-backed history. Heights are transaction versions (Aptos' global,
/// gap-free order). The indexer carries no hashes, so each transaction's
/// hash and status come from the node.
extension AptosClient {
    /// Pages are small: every transaction costs one node lookup.
    static let historyPageLimit = 25

    /// Processors whose output a page reads; the head never passes the
    /// slowest, so a forward scan can't skip versions still being indexed.
    static let historyProcessors = ["account_transactions_processor", "fungible_asset_processor"]

    public func transactionHistory(
        _ owner: AptosAddress,
        request: BlockchainTransactionHistoryRequest
    ) async throws -> BlockchainTransactionPage {
        let cursor = try request.cursor.map { try JSONDecoder().decode(AptosHistoryCursor.self, from: $0) }
        let indexerHead = try await indexedHead()
        let limit = min(Int(request.limit), Self.historyPageLimit)
        let lower: UInt64
        let upper: UInt64
        let head: UInt64

        switch request.direction {
        case .descending:
            head = request.upperBound ?? indexerHead
            lower = request.lowerBound ?? 0
            upper = cursor?.next ?? head
        case .ascending:
            head = min(request.upperBound ?? indexerHead, indexerHead)
            lower = cursor?.next ?? request.lowerBound ?? 0
            upper = head
        }

        guard lower <= upper else {
            return BlockchainTransactionPage(transactions: [], nextCursor: nil, reachedBoundary: true, head: head)
        }

        let versions = try await accountVersions(
            owner,
            lower: lower,
            upper: upper,
            descending: request.direction == .descending,
            limit: limit
        )

        let transactions = try await transactions(owner, versions: versions)
        let reachedBoundary = versions.count < limit
        let nextCursor: Data?

        if reachedBoundary {
            nextCursor = nil
        } else if let last = versions.last {
            let next = request.direction == .descending
                ? last.subtractingReportingOverflow(1)
                : last.addingReportingOverflow(1)
            nextCursor = next.overflow ? nil : try JSONEncoder().encode(AptosHistoryCursor(next: next.partialValue))
        } else {
            nextCursor = nil
        }

        return BlockchainTransactionPage(
            transactions: transactions,
            nextCursor: nextCursor,
            reachedBoundary: reachedBoundary || nextCursor == nil,
            head: head
        )
    }

    /// The newest version every history processor has indexed.
    func indexedHead() async throws -> UInt64 {
        let response: ProcessorStatusResponse = try await graphQL(
            """
            query Head($processors: [String!]!) {
              processor_status(where: {processor: {_in: $processors}}) { processor last_success_version }
            }
            """,
            variables: ["processors": Self.historyProcessors]
        )

        let versions = Dictionary(
            response.processorStatus.map { ($0.processor, $0.lastSuccessVersion) },
            uniquingKeysWith: max
        )

        guard Set(versions.keys) == Set(Self.historyProcessors), let head = versions.values.min() else {
            throw BlockchainClientError.invalidResponse(reason: "Aptos indexer reported no history processor status")
        }

        return head
    }
}

extension AptosClient {
    func accountVersions(
        _ owner: AptosAddress,
        lower: UInt64,
        upper: UInt64,
        descending: Bool,
        limit: Int
    ) async throws -> [UInt64] {
        let response: AccountTransactionsResponse = try await graphQL(
            """
            query Versions($owner: String!, $lower: bigint!, $upper: bigint!, $limit: Int!, $order: order_by!) {
              account_transactions(
                where: {account_address: {_eq: $owner}, transaction_version: {_gte: $lower, _lte: $upper}}
                order_by: {transaction_version: $order}
                limit: $limit
              ) { transaction_version }
            }
            """,
            variables: [
                "owner": owner.longString,
                "lower": String(lower),
                "upper": String(upper),
                "limit": limit,
                "order": descending ? "desc" : "asc"
            ]
        )

        return response.accountTransactions.map(\.transactionVersion)
    }

    func transactions(_ owner: AptosAddress, versions: [UInt64]) async throws -> [BlockchainTransaction] {
        guard !versions.isEmpty else {
            return []
        }

        async let pendingActivities = activities(owner, versions: versions)
        let statuses = try await withThrowingTaskGroup(of: (UInt64, AptosTransactionStatus).self) { group in
            for version in versions {
                group.addTask { (version, try await transaction(byVersion: version)) }
            }

            return try await group.reduce(into: [UInt64: AptosTransactionStatus]()) { $0[$1.0] = $1.1 }
        }

        let activitiesByVersion = Dictionary(grouping: try await pendingActivities, by: \.transactionVersion)
        let pairs = try await pairedAssetTypes(owner, activities: activitiesByVersion.values.flatMap { $0 })

        return versions.compactMap { version in
            guard let status = statuses[version] else {
                return nil
            }

            return Self.normalise(
                status,
                version: version,
                owner: owner,
                activities: activitiesByVersion[version] ?? [],
                pairs: pairs
            )
        }
    }

    func activities(_ owner: AptosAddress, versions: [UInt64]) async throws -> [AptosActivity] {
        let response: ActivitiesResponse = try await graphQL(
            """
            query Activities($owner: String!, $versions: [bigint!]!) {
              fungible_asset_activities(
                where: {owner_address: {_eq: $owner}, transaction_version: {_in: $versions}}
                order_by: [{transaction_version: asc}, {event_index: asc}]
              ) { transaction_version event_index amount asset_type type is_gas_fee storage_refund_amount }
            }
            """,
            variables: ["owner": owner.longString, "versions": versions.map(String.init)]
        )

        return response.fungibleAssetActivities
    }

    /// Maps Fungible Asset metadata addresses to their paired coin types for
    /// assets `owner` holds, so history and balances share one identifier.
    func pairedAssetTypes(_ owner: AptosAddress, activities: [AptosActivity]) async throws -> [String: String] {
        let needsPairs = activities.contains { activity in
            guard let assetType = activity.assetType else {
                return false
            }

            return !assetType.contains("::") && !Self.isNativeAsset(assetType)
        }

        guard needsPairs else {
            return [:]
        }

        return try await indexedBalances(of: owner).reduce(into: [:]) { pairs, balance in
            if let fungibleAssetType = balance.fungibleAssetType, fungibleAssetType != balance.assetType {
                pairs[fungibleAssetType] = balance.assetType
            }
        }
    }

    static func normalise(
        _ status: AptosTransactionStatus,
        version: UInt64,
        owner: AptosAddress,
        activities: [AptosActivity],
        pairs: [String: String]
    ) -> BlockchainTransaction {
        var netByAsset: [String: Decimal] = [:]
        var order: [String] = []

        for activity in activities {
            guard let rawAssetType = activity.assetType, let delta = activity.delta else {
                continue
            }

            let canonical = canonicalAssetType(rawAssetType)
            let assetType = pairs[canonical] ?? canonical

            if netByAsset[assetType] == nil {
                order.append(assetType)
            }

            netByAsset[assetType, default: 0] += delta
        }

        let effects = order.enumerated().compactMap { index, assetType -> BlockchainTransactionEffect? in
            guard let amount = netByAsset[assetType], amount != 0 else {
                return nil
            }

            // Signed net amounts. Transfer kinds (not `.balanceChange`) so the
            // app discovers tokens and refreshes balances from history.
            let isNative = assetType == nativeCoinType

            return BlockchainTransactionEffect(
                index: UInt64(index),
                kind: isNative ? .nativeTransfer : .tokenTransfer,
                assetIdentifier: isNative ? nil : assetType,
                amount: NSDecimalNumber(decimal: amount).stringValue,
                to: owner.string
            )
        }

        return BlockchainTransaction(
            identifier: status.hash,
            blockHeight: version,
            timestamp: status.timestamp.map { Date(timeIntervalSince1970: TimeInterval($0) / 1_000_000) },
            sender: status.sender.flatMap { try? AptosAddress(chainString: $0).string },
            status: status.success == false ? .reverted : .confirmed,
            effects: effects
        )
    }
}

private struct AptosHistoryCursor: Codable {
    /// The next version to read, inclusive, in the scan's direction.
    let next: UInt64
}

private struct ProcessorStatusResponse: Decodable {
    struct Row: Decodable {
        let lastSuccessVersion: UInt64
        let processor: String

        enum CodingKeys: String, CodingKey {
            case lastSuccessVersion = "last_success_version"
            case processor
        }
    }

    let processorStatus: [Row]

    enum CodingKeys: String, CodingKey {
        case processorStatus = "processor_status"
    }
}

private struct AccountTransactionsResponse: Decodable {
    struct Row: Decodable {
        let transactionVersion: UInt64

        enum CodingKeys: String, CodingKey {
            case transactionVersion = "transaction_version"
        }
    }

    let accountTransactions: [Row]

    enum CodingKeys: String, CodingKey {
        case accountTransactions = "account_transactions"
    }
}

struct AptosActivity: Decodable, Sendable {
    let amount: AptosIndexerNumber?
    let assetType: String?
    let eventIndex: Int64?
    let isGasFee: Bool
    let storageRefundAmount: AptosIndexerNumber?
    let transactionVersion: UInt64
    let type: String

    enum CodingKeys: String, CodingKey {
        case amount
        case assetType = "asset_type"
        case eventIndex = "event_index"
        case isGasFee = "is_gas_fee"
        case storageRefundAmount = "storage_refund_amount"
        case transactionVersion = "transaction_version"
        case type
    }

    /// The signed change to the owner's balance: deposits add, withdrawals
    /// and gas (net of storage refund) subtract; other events are ignored.
    var delta: Decimal? {
        guard let amount = amount.flatMap({ Decimal(string: $0.description) }) else {
            return nil
        }

        if isGasFee {
            let refund = storageRefundAmount.flatMap { Decimal(string: $0.description) } ?? 0
            return refund - amount
        }

        let event = type.split(separator: "::").last.map(String.init) ?? type

        switch event {
        case "Deposit", "DepositEvent": return amount
        case "Withdraw", "WithdrawEvent": return -amount
        default: return nil
        }
    }
}

private struct ActivitiesResponse: Decodable {
    let fungibleAssetActivities: [AptosActivity]

    enum CodingKeys: String, CodingKey {
        case fungibleAssetActivities = "fungible_asset_activities"
    }
}
