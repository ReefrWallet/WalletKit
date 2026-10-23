//
//  SuiHistoryCursor.swift
//  WalletKit
//
//  Created by Andrey Yurkevich on 18/09/2026.
//  Copyright © 2026 Reefr Wallet. All rights reserved.
//

import GRPCCore
import WalletKitGRPC

private struct SuiHistoryCursor: Codable {
    let cursor: Data
    let upperBound: UInt64
    let lowerBound: UInt64
    let direction: BlockchainTransactionScanDirection
}

extension SuiGRPCClient {
    /// Pages transactions matching either the account sender or affected
    /// address. Sui's watermark cursor is persisted without interpretation so
    /// the node remains authoritative about pagination and scan-limit resumes.
    public func transactionHistory( // swiftlint:disable:this function_body_length
        _ owner: SuiAddress,
        request: BlockchainTransactionHistoryRequest
    ) async throws -> BlockchainTransactionPage {
        let savedCursor = try request.cursor.map { try JSONDecoder().decode(SuiHistoryCursor.self, from: $0) }

        let direction = savedCursor?.direction ?? request.direction
        let head = try await suiTransactionHead()
        let lowerBound = savedCursor?.lowerBound ?? request.lowerBound ?? 0
        let upperBound = savedCursor?.upperBound ?? request.upperBound ?? head

        // swiftlint:disable:next large_tuple
        let result: ([Sui_Rpc_V2_ExecutedTransaction], Data?, Bool) = try await withLedgerServiceClient { ledger in
            let grpcRequest = Sui_Rpc_V2_ListTransactionsRequest.with {
                // Public full nodes can prune their earliest checkpoints. Leave
                // the initial zero lower bound unset so the node uses its
                // retained-history boundary instead of rejecting the request.
                if lowerBound > 0 {
                    $0.startCheckpoint = lowerBound
                }

                $0.endCheckpoint = upperBound + 1
                $0.filter = Self.transactionFilter(owner)
                $0.options = Sui_Rpc_V2_QueryOptions.with {
                    $0.limit = request.limit
                    $0.ordering = direction == .descending ? .descending : .ascending
                    if let cursor = savedCursor?.cursor {
                        if direction == .descending {
                            $0.before = cursor
                        } else {
                            $0.after = cursor
                        }
                    }
                }

                $0.readMask.paths = [
                    "digest", "transaction.sender", "transaction.kind", "checkpoint", "timestamp",
                    "balance_changes", "effects"
                ]
            }

            return try await ledger.listTransactions(
                request: ClientRequest(message: grpcRequest),
                options: self.callOptions
            ) { response in
                var transactions: [Sui_Rpc_V2_ExecutedTransaction] = []
                var watermark: Data?
                var reachedBoundary = false

                for try await message in response.messages {
                    if message.hasTransaction {
                        transactions.append(message.transaction)
                    }

                    if message.watermark.hasCursor {
                        watermark = message.watermark.cursor
                    }

                    if message.hasEnd {
                        reachedBoundary = message.end.reason != .itemLimit && message.end.reason != .scanLimit
                    }
                }

                return (transactions, watermark, reachedBoundary)
            }
        }

        let transactions = result.0.map(Self.normalise)
        let nextCursor = result.1.map {
            try? JSONEncoder().encode(
                SuiHistoryCursor(
                    cursor: $0,
                    upperBound: upperBound,
                    lowerBound: lowerBound,
                    direction: direction
                )
            )
        } ?? nil

        return BlockchainTransactionPage(
            transactions: transactions,
            nextCursor: nextCursor,
            reachedBoundary: result.2 || result.1 == nil,
            head: upperBound
        )
    }

    /// Streams matching Sui transaction watermarks. The synchroniser uses the
    /// checkpoint watermark only as a forward recovery boundary; all durable
    /// activity still enters through the paged history API.
    public func transactionHeads(
        _ owner: SuiAddress
    ) -> AsyncThrowingStream<BlockchainTransactionHead, any Swift.Error> {
        // Checkpoints (~4/s) outpace scans; a scan covers everything up to its head.
        AsyncThrowingStream(bufferingPolicy: .bufferingNewest(1)) { continuation in
            let task = Task {
                do {
                    try await withSubscriptionServiceClient { service in
                        let request = Sui_Rpc_V2_SubscribeTransactionsRequest.with {
                            $0.filter = Self.transactionFilter(owner)
                            $0.readMask.paths = ["digest", "checkpoint"]
                        }

                        try await service.subscribeTransactions(
                            request: ClientRequest(message: request),
                            options: .defaults
                        ) { response in
                            for try await message in response.messages {
                                if message.transaction.hasCheckpoint {
                                    continuation.yield(
                                        BlockchainTransactionHead(height: message.transaction.checkpoint)
                                    )
                                } else if message.watermark.hasCheckpoint {
                                    continuation.yield(
                                        BlockchainTransactionHead(height: message.watermark.checkpoint)
                                    )
                                }
                            }
                        }
                    }

                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }

            continuation.onTermination = { _ in task.cancel() }
        }
    }
}

private extension SuiGRPCClient {
    func suiTransactionHead() async throws -> UInt64 {
        try await withLedgerServiceClient { ledger in
            let response = try await ledger.getServiceInfo(
                request: ClientRequest(message: Sui_Rpc_V2_GetServiceInfoRequest()),
                options: self.callOptions
            )

            return response.checkpointHeight
        }
    }

    static func transactionFilter(_ owner: SuiAddress) -> Sui_Rpc_V2_TransactionFilter {
        Sui_Rpc_V2_TransactionFilter.with {
            $0.terms = [
                Sui_Rpc_V2_TransactionTerm.with {
                    $0.literals = [Sui_Rpc_V2_TransactionLiteral.with {
                        $0.sender.address = owner.string
                    }]
                },
                Sui_Rpc_V2_TransactionTerm.with {
                    $0.literals = [Sui_Rpc_V2_TransactionLiteral.with {
                        $0.affectedAddress.address = owner.string
                    }]
                }

            ]
        }
    }

    static func normalise(_ transaction: Sui_Rpc_V2_ExecutedTransaction) -> BlockchainTransaction {
        let timestamp: Date?
        if transaction.hasTimestamp {
            timestamp = Date(
                timeIntervalSince1970: TimeInterval(transaction.timestamp.seconds)
                    + TimeInterval(transaction.timestamp.nanos) / 1_000_000_000
            )
        } else {
            timestamp = nil
        }

        let effects = transaction.balanceChanges.enumerated().map { index, change in
            BlockchainTransactionEffect(
                index: UInt64(index),
                kind: .balanceChange,
                assetIdentifier: change.coinType,
                amount: change.amount,
                to: change.address
            )
        }

        let commands = transaction.transaction.kind.programmableTransaction.commands
        let moveCalls = commands.compactMap { command -> Sui_Rpc_V2_MoveCall? in
            guard case let .moveCall(call)? = command.command else {
                return nil
            }

            return call
        }

        let isSuccess = !transaction.effects.hasStatus || transaction.effects.status.success

        return BlockchainTransaction(
            identifier: transaction.digest,
            blockHeight: transaction.hasCheckpoint ? transaction.checkpoint : nil,
            timestamp: timestamp,
            transactionIndex: transaction.hasTransactionIndex ? transaction.transactionIndex : nil,
            sender: transaction.hasTransaction ? transaction.transaction.sender : nil,
            status: isSuccess ? .confirmed : .failed,
            rawPayload: try? transaction.serializedData(),
            effects: effects,
            counterpartyName: moveCalls.first.flatMap { isSuiSystem($0.package) ? "Sui System" : nil },
            fee: transaction.effects.hasGasUsed ? fee(transaction.effects.gasUsed) : nil,
            method: method(commands: commands, moveCalls: moveCalls)
        )
    }

    static func fee(_ gas: Sui_Rpc_V2_GasCostSummary) -> String {
        let cost = Int64(gas.computationCost) + Int64(gas.storageCost) - Int64(gas.storageRebate)
        return String(max(cost, 0))
    }

    static func isSuiSystem(_ package: String) -> Bool {
        package.drop0x.drop { $0 == "0" } == "3"
    }

    static func method(commands: [Sui_Rpc_V2_Command], moveCalls: [Sui_Rpc_V2_MoveCall]) -> String? {
        switch moveCalls.count {
        case 0:
            return commands.isEmpty ? nil : "Send"
        case 1:
            let function = moveCalls[0].function
            return ["request_add_stake": "Stake", "request_withdraw_stake": "Unstake"][function] ?? function
        default:
            return "Programmable Tx"
        }
    }
}

private extension String {
    var drop0x: Substring {
        hasPrefix("0x") ? dropFirst(2) : Substring(self)
    }
}
