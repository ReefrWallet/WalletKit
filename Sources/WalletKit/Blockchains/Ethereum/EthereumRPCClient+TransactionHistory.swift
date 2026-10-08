//
//  EthereumRPCClient+TransactionHistory.swift
//  WalletKit
//

import BigInt
import Foundation

private struct EVMHistoryCursor: Codable {
    let nextBlock: UInt64
    let upperBound: UInt64
    let lowerBound: UInt64
    let direction: BlockchainTransactionScanDirection
}

private struct EVMBlockRequest: Encodable {
    let block: String
    let includeTransactions: Bool

    func encode(to encoder: Encoder) throws {
        var container = encoder.unkeyedContainer()
        try container.encode(block)
        try container.encode(includeTransactions)
    }
}

private struct EVMHistoryBlock: Codable {
    let number: String?
    let hash: String?
    let timestamp: String?
    let transactions: [EVMHistoryTransaction]
}

private struct EVMHistoryTransaction: Codable {
    let hash: String
    let from: String
    let to: String?
    let value: String?
    let transactionIndex: String?
}

private struct EVMLogFilter: Encodable {
    var address: [String]?
    let fromBlock: String
    let toBlock: String
    let topics: [String?]
}

private struct EVMHistoryLog: Codable {
    let address: String
    let blockHash: String?
    let blockNumber: String?
    let data: String
    let logIndex: String?
    let topics: [String]
    let transactionHash: String
}

private struct EVMTransactionReceipt: Decodable {
    let status: String?
}

private struct EVMHeadSubscriptionResponse: Decodable {
    let params: Parameters?

    struct Parameters: Decodable {
        let result: Head
    }

    struct Head: Decodable {
        let number: String
        let hash: String?
        let parentHash: String?
    }
}

extension EthereumRPCClient {
    /// Pages direct account transactions from standard EVM full-block RPC
    /// responses. The cursor always retains the original range boundary, so a
    /// resumed descending scan cannot silently jump to a newer chain head.
    public func transactionHistory( // swiftlint:disable:this function_body_length
        _ owner: EthereumAddress,
        request: BlockchainTransactionHistoryRequest
    ) async throws -> BlockchainTransactionPage {
        let cursor = try request.cursor.map { try JSONDecoder().decode(EVMHistoryCursor.self, from: $0) }

        let currentHead = try await blockHeight()
        let lowerBound = cursor?.lowerBound ?? request.lowerBound ?? 0
        let upperBound = cursor?.upperBound ?? request.upperBound ?? currentHead
        let direction = cursor?.direction ?? request.direction
        let block = cursor?.nextBlock ?? (direction == .descending ? upperBound : lowerBound)

        guard lowerBound <= upperBound else {
            return BlockchainTransactionPage(
                transactions: [],
                nextCursor: nil,
                reachedBoundary: true,
                head: currentHead
            )
        }

        let blockLimit = max(1, min(Int(request.limit), 10))
        let blocks = historyBlocks(
            from: block,
            direction: direction,
            lowerBound: lowerBound,
            limit: blockLimit,
            upperBound: upperBound
        )

        let fetchedBlocks: [EVMHistoryBlock?] = try await rpc.callBatch(
            method: "eth_getBlockByNumber",
            params: blocks.map {
                EVMBlockRequest(
                    block: "0x" + String($0, radix: 16),
                    includeTransactions: true
                )
            }
        )

        let effectsByBlock: [UInt64: [(transactionHash: String, effect: BlockchainTransactionEffect)]]

        do {
            effectsByBlock = try await tokenEffects(owner: owner.string, blocks: blocks, contracts: nil)
        } catch {
            // Public RPC nodes (e.g. PublicNode) reject log queries without an
            // `address` — retry scoped to the account's known token contracts.
            // Native transfers remain discoverable from the block's transaction list.
            let contracts = Array(Set(request.assetHints.compactMap { try? EthereumAddress(string: $0).string }))

            if contracts.isEmpty {
                effectsByBlock = [:]
            } else {
                effectsByBlock = (try? await tokenEffects(
                    owner: owner.string,
                    blocks: blocks,
                    contracts: contracts
                )) ?? [:]
            }
        }

        var transactions: [BlockchainTransaction] = []

        for (block, fetched) in zip(blocks, fetchedBlocks) {
            guard let fetched else {
                continue
            }

            let timestamp = try fetched
                .timestamp
                .flatMap(parseEVMQuantity)
                .map { Date(timeIntervalSince1970: TimeInterval($0)) }

            let blockHash = fetched.hash
            var records: [String: BlockchainTransaction] = [:]

            for transaction in fetched.transactions where matches(owner: owner.string, transaction: transaction) {
                let rawPayload = try? JSONEncoder().encode(transaction)
                records[transaction.hash] = BlockchainTransaction(
                    identifier: transaction.hash,
                    blockHeight: block,
                    blockHash: blockHash,
                    timestamp: timestamp,
                    transactionIndex: try transaction.transactionIndex.flatMap(parseEVMQuantity),
                    sender: transaction.from,
                    recipient: transaction.to,
                    status: .unconfirmed,
                    rawPayload: rawPayload,
                    effects: nativeTransferEffect(transaction).map { [$0] } ?? []
                )
            }

            for effect in effectsByBlock[block, default: []] {
                if let current = records[effect.transactionHash] {
                    records[effect.transactionHash] = BlockchainTransaction(
                        identifier: current.identifier,
                        blockHeight: current.blockHeight,
                        blockHash: current.blockHash,
                        timestamp: current.timestamp,
                        transactionIndex: current.transactionIndex,
                        sender: current.sender,
                        recipient: current.recipient,
                        status: current.status,
                        rawPayload: current.rawPayload,
                        effects: current.effects + [effect.effect]
                    )
                } else {
                    records[effect.transactionHash] = BlockchainTransaction(
                        identifier: effect.transactionHash,
                        blockHeight: block,
                        blockHash: blockHash,
                        timestamp: timestamp,
                        status: .unconfirmed,
                        effects: [effect.effect]
                    )
                }
            }

            transactions.append(contentsOf: records.values)
        }

        transactions = await applyConfirmationStatus(to: transactions)

        let reachedBoundary = blocks.last == (direction == .descending ? lowerBound : upperBound)
        let nextCursor = reachedBoundary ? nil : try JSONEncoder().encode(
            EVMHistoryCursor(
                nextBlock: direction == .descending ? block - UInt64(blocks.count) : block + UInt64(blocks.count),
                upperBound: upperBound,
                lowerBound: lowerBound,
                direction: direction
            )
        )

        return BlockchainTransactionPage(
            transactions: transactions,
            nextCursor: nextCursor,
            reachedBoundary: reachedBoundary,
            head: upperBound
        )
    }

    /// Subscribes to standard `eth_subscribe` / `newHeads` notifications.
    /// An HTTP-only endpoint reports an unsupported feature to the caller,
    /// which can continue using bounded forward polling.
    public func transactionHeads(
        _ owner: EthereumAddress
    ) -> AsyncThrowingStream<BlockchainTransactionHead, any Swift.Error> {
        guard let websocketURL = websocketEndpoint else {
            return AsyncThrowingStream { continuation in
                continuation.finish(throwing: WalletKitError.unsupportedFeature)
            }
        }

        return AsyncThrowingStream { continuation in
            let task = Task {
                let socket = rpc.session.webSocketTask(with: websocketURL)
                socket.resume()

                defer { socket.cancel(with: .goingAway, reason: nil) }

                do {
                    let payload: [String: Any] = [
                        "jsonrpc": "2.0",
                        "id": 1,
                        "method": "eth_subscribe",
                        "params": ["newHeads"]
                    ]

                    try await socket.send(.data(JSONSerialization.data(withJSONObject: payload)))

                    while !Task.isCancelled {
                        let message = try await socket.receive()
                        let data: Data

                        switch message {
                        case let .data(value): data = value
                        case let .string(value): data = Data(value.utf8)
                        @unknown default: continue
                        }

                        guard
                            let response = try? JSONDecoder().decode(EVMHeadSubscriptionResponse.self, from: data),
                            let head = response.params?.result
                        else {
                            continue
                        }

                        continuation.yield(
                            BlockchainTransactionHead(
                                height: try parseEVMQuantity(head.number),
                                hash: head.hash,
                                parentHash: head.parentHash
                            )
                        )
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

private extension EthereumRPCClient {
    func blockHeight() async throws -> UInt64 {
        let raw: String = try await rpc.call(method: "eth_blockNumber", params: [String]())
        return try parseEVMQuantity(raw)
    }

    /// Promotes each transaction from the default `.unconfirmed` set while
    /// building the page to `.confirmed`/`.failed` based on its mined
    /// receipt. Best-effort: a node that rejects the batch receipt call
    /// leaves every transaction `.unconfirmed` rather than failing history
    /// sync outright, mirroring `tokenEffects`'s degrade-on-error behavior.
    func applyConfirmationStatus(to transactions: [BlockchainTransaction]) async -> [BlockchainTransaction] {
        guard !transactions.isEmpty else {
            return transactions
        }

        let receipts: [EVMTransactionReceipt?]

        do {
            receipts = try await rpc.callBatch(
                method: "eth_getTransactionReceipt",
                params: transactions.map { [$0.identifier] }
            )
        } catch {
            return transactions
        }

        return zip(transactions, receipts).map { transaction, receipt in
            guard let status = receipt?.status else {
                return transaction
            }

            return BlockchainTransaction(
                identifier: transaction.identifier,
                blockHeight: transaction.blockHeight,
                blockHash: transaction.blockHash,
                timestamp: transaction.timestamp,
                transactionIndex: transaction.transactionIndex,
                sender: transaction.sender,
                recipient: transaction.recipient,
                status: status == "0x1" ? .confirmed : .failed,
                rawPayload: transaction.rawPayload,
                effects: transaction.effects
            )
        }
    }

    func matches(owner: String, transaction: EVMHistoryTransaction) -> Bool {
        let owner = owner.lowercased()
        return transaction.from.lowercased() == owner || transaction.to?.lowercased() == owner
    }

    func nativeTransferEffect(_ transaction: EVMHistoryTransaction) -> BlockchainTransactionEffect? {
        guard
            let value = transaction.value,
            let amount = BigUInt(value.drop0xPrefix(), radix: 16),
            amount > 0
        else {
            return nil
        }

        return BlockchainTransactionEffect(
            index: 0,
            kind: .nativeTransfer,
            amount: amount.description,
            from: transaction.from,
            to: transaction.to
        )
    }

    func historyBlocks(
        from block: UInt64,
        direction: BlockchainTransactionScanDirection,
        lowerBound: UInt64,
        limit: Int,
        upperBound: UInt64
    ) -> [UInt64] {
        var blocks: [UInt64] = []
        var nextBlock = block

        while blocks.count < limit, nextBlock >= lowerBound, nextBlock <= upperBound {
            blocks.append(nextBlock)

            switch direction {
            case .descending:
                guard nextBlock > lowerBound else {
                    return blocks
                }

                nextBlock -= 1
            case .ascending:
                guard nextBlock < upperBound else {
                    return blocks
                }

                nextBlock += 1
            }
        }

        return blocks
    }

    func tokenEffects(
        owner: String,
        blocks: [UInt64],
        contracts: [String]?
    ) async throws -> [UInt64: [(transactionHash: String, effect: BlockchainTransactionEffect)]] {
        guard let lowerBound = blocks.min(), let upperBound = blocks.max() else {
            return [:]
        }

        let fromBlock = "0x" + String(lowerBound, radix: 16)
        let toBlock = "0x" + String(upperBound, radix: 16)
        let ownerTopic = "0x" + String(repeating: "0", count: 24) + owner.drop0xPrefix().lowercased()
        let transfer = "0xddf252ad1be2c89b69c2b068fc378daa952ba7f163c4a11628f55a4df523b3ef"
        let approval = "0x8c5be1e5ebec7d5bd14f71427d1e84f3dd0314c0f7b2291e5b200ac8c7c3b925"

        async let sent: [EVMHistoryLog] = logs(
            EVMLogFilter(
                address: contracts,
                fromBlock: fromBlock,
                toBlock: toBlock,
                topics: [transfer, ownerTopic, nil]
            )
        )

        async let received: [EVMHistoryLog] = logs(
            EVMLogFilter(
                address: contracts,
                fromBlock: fromBlock,
                toBlock: toBlock,
                topics: [transfer, nil, ownerTopic]
            )
        )

        async let approvals: [EVMHistoryLog] = logs(
            EVMLogFilter(
                address: contracts,
                fromBlock: fromBlock,
                toBlock: toBlock,
                topics: [approval, ownerTopic, nil]
            )
        )

        let sentLogs = try await sent
        let receivedLogs = try await received
        let approvalLogs = try await approvals
        var effectsByBlock: [UInt64: [(transactionHash: String, effect: BlockchainTransactionEffect)]] = [:]

        for log in sentLogs + receivedLogs {
            guard let blockNumber = try log.blockNumber.map(parseEVMQuantity) else {
                continue
            }

            effectsByBlock[blockNumber, default: []].append(makeTransferEffect(log))
        }

        for log in approvalLogs {
            guard let blockNumber = try log.blockNumber.map(parseEVMQuantity) else {
                continue
            }

            effectsByBlock[blockNumber, default: []].append(makeApprovalEffect(log))
        }

        return effectsByBlock
    }

    func logs(_ filter: EVMLogFilter) async throws -> [EVMHistoryLog] {
        try await rpc.call(method: "eth_getLogs", params: [filter])
    }

    func makeTransferEffect(_ log: EVMHistoryLog) -> (transactionHash: String, effect: BlockchainTransactionEffect) {
        (
            log.transactionHash,
            BlockchainTransactionEffect(
                index: (try? log.logIndex.flatMap(parseEVMQuantity)) ?? 0,
                kind: .tokenTransfer,
                assetIdentifier: (try? EthereumAddress(string: log.address).string) ?? log.address,
                amount: amount(log.data),
                from: log.topics.count > 1 ? address(log.topics[1]) : nil,
                to: log.topics.count > 2 ? address(log.topics[2]) : nil,
                rawPayload: try? JSONEncoder().encode(log)
            )
        )
    }

    func makeApprovalEffect(_ log: EVMHistoryLog) -> (transactionHash: String, effect: BlockchainTransactionEffect) {
        (
            log.transactionHash,
            BlockchainTransactionEffect(
                index: (try? log.logIndex.flatMap(parseEVMQuantity)) ?? 0,
                kind: .tokenApproval,
                assetIdentifier: (try? EthereumAddress(string: log.address).string) ?? log.address,
                amount: amount(log.data),
                from: log.topics.count > 1 ? address(log.topics[1]) : nil,
                to: log.topics.count > 2 ? address(log.topics[2]) : nil,
                rawPayload: try? JSONEncoder().encode(log)
            )
        )
    }

    func amount(_ data: String) -> String? {
        BigUInt(data.drop0xPrefix(), radix: 16)?.description
    }

    func address(_ topic: String) -> String? {
        let value = topic.drop0xPrefix()
        guard value.count == 64 else {
            return nil
        }

        return "0x" + String(value.suffix(40))
    }

    var websocketEndpoint: URL? {
        guard var components = URLComponents(url: rpc.endpoint, resolvingAgainstBaseURL: false) else {
            return nil
        }

        switch components.scheme?.lowercased() {
        case "https": components.scheme = "wss"
        case "http": components.scheme = "ws"
        case "wss", "ws": break
        default: return nil
        }

        return components.url
    }
}

private extension String {
    func drop0xPrefix() -> String {
        hasPrefix("0x") ? String(dropFirst(2)) : self
    }
}

private func parseEVMQuantity(_ value: String) throws -> UInt64 {
    let digits = value.hasPrefix("0x") ? String(value.dropFirst(2)) : value

    guard let quantity = UInt64(digits, radix: 16) else {
        throw BlockchainClientError.decodingFailed(reason: "invalid EVM quantity: \(value)")
    }

    return quantity
} // swiftlint:disable:this file_length
