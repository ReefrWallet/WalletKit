import Foundation

extension CardanoClient {
    /// Returns one page of `owner`'s transaction history — Blockfrost's
    /// `accounts/{stake_address}/transactions`, using a stable query for
    /// each requested page.
    ///
    /// - Descending (backfill): pages from `upperBound` toward the account's
    ///   oldest transaction; `reachedBoundary` is `true` on the first short
    ///   page, which also ends the scan.
    /// - Ascending (forward catch-up): pages through the gap above what's
    ///   already synced. A short page closes the gap, and the returned cursor
    ///   pins the *next* pass to just past the newest transaction this one
    ///   saw — so an idle poll reads one page, not the whole history.
    public func transactionHistory(
        _ owner: CardanoAccountDescriptor,
        request: BlockchainTransactionHistoryRequest
    ) async throws -> BlockchainTransactionPage {
        let cursor = request.cursor.flatMap(HistoryCursor.init(data:))
        let count = min(max(Int(request.limit), 1), 100)
        let page = max(1, cursor?.page ?? 1)
        // Pinned for every page of one pass — see `historyQuery`.
        let from = cursor?.from ?? request.lowerBound.flatMap { $0 > 0 ? "\($0)" : nil }

        let addresses = (try? await ownedAddresses(owner)).map { Set($0) } ?? []

        let transactions: [AccountTransaction] = try await get(
            "accounts/\(owner.stakeAddress)/transactions",
            query: historyQuery(request: request, count: count, from: from, page: page)
        )

        let reachedBoundary = transactions.count < count
        let nextCursor: HistoryCursor?

        switch (reachedBoundary, request.direction) {
        case (false, _):
            nextCursor = HistoryCursor(from: from, page: page + 1)
        case (true, .ascending):
            // The gap is closed. Resume the next pass immediately after the
            // newest transaction this one saw: `request.lowerBound` is only
            // block-granular, so resuming from it would re-read the head
            // block on every idle poll and hand `TransactionSyncService` a
            // non-empty page — and so a balance refresh — every 10 seconds
            // (ADR-008). Ascending order puts the newest entry last.
            nextCursor = HistoryCursor(from: transactions.last?.resumePoint ?? from, page: 1)
        case (true, .descending):
            nextCursor = nil
        }

        // Forward sync stays parked until it has seen a head, and Blockfrost's
        // account history carries no chain tip of its own — report the newest
        // block this page touched. Only a caller with no head at all (a
        // `lowerBound` of nil/0, i.e. backfill) pays for a `blocks/latest`
        // read when its page carries no height, so an account with no history
        // still produces one; a failed tip read must not sink an otherwise-good
        // page, so it degrades to no head and the next poll retries.
        var head = transactions.compactMap(\.blockHeight).max()

        if head == nil, (request.lowerBound ?? 0) == 0 {
            head = try? await latestBlockHeight()
        }

        var blockchainTransactions: [BlockchainTransaction] = []

        for transaction in transactions {
            let effect = try? await nativeTransferEffect(
                txHash: transaction.txHash,
                owner: owner,
                ownedAddresses: addresses
            )

            let details: TransactionDetails? = try? await get("txs/\(transaction.txHash)")

            blockchainTransactions.append(
                BlockchainTransaction(
                    identifier: transaction.txHash,
                    blockHeight: transaction.blockHeight,
                    blockHash: transaction.block,
                    timestamp: Date(timeIntervalSince1970: TimeInterval(transaction.blockTime)),
                    status: .confirmed,
                    effects: effect.map { [$0] } ?? [],
                    fee: details?.fees,
                    method: effect.map { $0.from != nil ? "Sent" : $0.to != nil ? "Received" : "Self Transfer" }
                )
            )
        }

        return BlockchainTransactionPage(
            transactions: blockchainTransactions,
            nextCursor: try nextCursor.map { try JSONEncoder().encode($0) },
            reachedBoundary: reachedBoundary,
            head: head
        )
    }
}

extension CardanoClient {
    struct AddressEntry: Decodable {
        let address: String
    }

    struct AccountTransaction: Decodable {
        let block: String?
        let blockHeight: UInt64?
        let blockTime: UInt64
        let txHash: String
        let txIndex: UInt32?

        enum CodingKeys: String, CodingKey {
            case block
            case blockHeight = "block_height"
            case blockTime = "block_time"
            case txHash = "tx_hash"
            case txIndex = "tx_index"
        }

        /// Where an ascending pass resumes so it never re-reads this
        /// transaction — `from`'s `block:index` form, one index past it.
        /// `nil` while this transaction has no block of its own.
        var resumePoint: String? {
            guard let blockHeight else {
                return nil
            }

            // `tx_index` is always present in practice; without it, resume at
            // the block itself and re-read it rather than risk skipping a
            // sibling transaction in the same block.
            guard let txIndex else {
                return "\(blockHeight)"
            }

            return "\(blockHeight):\(txIndex + 1)"
        }
    }

    /// `blocks/latest`. `height` is null only for the genesis block.
    struct Block: Decodable {
        let height: UInt64?
    }

    /// `txs/{hash}`; only the fee is read.
    struct TransactionDetails: Decodable {
        let fees: String?
    }

    struct TransactionUTxOs: Decodable {
        let inputs: [TransactionUTxO]
        let outputs: [TransactionUTxO]
    }

    struct TransactionUTxO: Decodable {
        let address: String
        let amount: [TransactionAmount]
    }

    struct TransactionAmount: Decodable {
        let quantity: String
        let unit: String
    }

    func nativeTransferEffect(
        txHash: String,
        owner: CardanoAccountDescriptor,
        ownedAddresses: Set<String>
    ) async throws -> BlockchainTransactionEffect? {
        guard !ownedAddresses.isEmpty else {
            return nil
        }

        let transaction: TransactionUTxOs = try await get("txs/\(txHash)/utxos")
        let received = lovelace(in: transaction.outputs, ownedAddresses: ownedAddresses)
        let sent = lovelace(in: transaction.inputs, ownedAddresses: ownedAddresses)
        let net = received - sent

        return BlockchainTransactionEffect(
            index: 0,
            kind: .nativeTransfer,
            amount: String(net.magnitude),
            from: net < 0 ? owner.string : nil,
            to: net > 0 ? owner.string : nil
        )
    }

    func lovelace(in entries: [TransactionUTxO], ownedAddresses: Set<String>) -> Int64 {
        var total: Int64 = 0

        for entry in entries where ownedAddresses.contains(entry.address) {
            for amount in entry.amount where amount.unit == "lovelace" {
                total += Int64(amount.quantity) ?? 0
            }
        }

        return total
    }

    func ownedAddresses(_ owner: CardanoAccountDescriptor) async throws -> [String] {
        let count = 100
        var addresses: [String] = []
        var page = 1

        while true {
            let entries: [AddressEntry] = try await get(
                "accounts/\(owner.stakeAddress)/addresses",
                query: [
                    URLQueryItem(name: "count", value: "\(count)"),
                    URLQueryItem(name: "page", value: "\(page)")
                ]
            )

            addresses.append(contentsOf: entries.map(\.address))

            guard entries.count == count else {
                return addresses
            }

            page += 1
        }
    }

    /// What ``CardanoClient/transactionHistory(_:request:)`` persists between
    /// pages: Blockfrost's ordinal `page` number within the pass in progress,
    /// and the `from` bound that pass pinned its window to.
    ///
    /// An ascending pass that drains carries its resume point over as the
    /// *next* pass's `from`, at `page` 1.
    struct HistoryCursor: Codable {
        let from: String?
        let page: Int

        init(from: String?, page: Int) {
            self.from = from
            self.page = page
        }

        init?(data: Data) {
            if let decoded = try? JSONDecoder().decode(HistoryCursor.self, from: data) {
                self = decoded
                return
            }

            // A cursor persisted before this carried anything but a page
            // number, so an in-flight backfill resumes where it left off
            // instead of restarting from Blockfrost's first page.
            guard let strPage = String(bytes: data, encoding: .utf8), let page = Int(strPage) else {
                return nil
            }

            self.init(from: nil, page: page)
        }
    }

    /// The query for one page of `accounts/{stake_address}/transactions`.
    ///
    /// Blockfrost pages that endpoint by ordinal page number, which only
    /// keeps meaning the same thing while the window those pages cover holds
    /// still. `from`/`to` (inclusive, `block` or `block:index`) pin the
    /// window to the range the caller asked for:
    ///
    /// - Ascending (forward catch-up) pins the window's *start*, so a pass
    ///   reads only the gap above what's already synced — usually one short
    ///   page per poll — instead of walking the account's whole history from
    ///   its oldest page on every pass. Newly confirmed transactions append
    ///   past the window's end without renumbering what's inside it.
    /// - Descending (backfill) pins the window's *end* at `upperBound`, the
    ///   head backfill started from, so transactions arriving mid-backfill
    ///   can't shift every remaining page by one and drop a transaction at a
    ///   page seam.
    func historyQuery(
        request: BlockchainTransactionHistoryRequest,
        count: Int,
        from: String?,
        page: Int
    ) -> [URLQueryItem] {
        var query = [
            URLQueryItem(name: "count", value: "\(count)"),
            URLQueryItem(name: "order", value: request.direction == .ascending ? "asc" : "desc"),
            URLQueryItem(name: "page", value: "\(page)")
        ]

        if let from {
            query.append(URLQueryItem(name: "from", value: from))
        }

        if let upperBound = request.upperBound {
            query.append(URLQueryItem(name: "to", value: "\(upperBound)"))
        }

        return query
    }

    /// The current chain tip's block height.
    func latestBlockHeight() async throws -> UInt64 {
        let block: Block = try await get("blocks/latest")

        guard let height = block.height else {
            throw WalletKitError.internalError(message: "Blockfrost returned no Cardano block height.")
        }

        return height
    }
}
