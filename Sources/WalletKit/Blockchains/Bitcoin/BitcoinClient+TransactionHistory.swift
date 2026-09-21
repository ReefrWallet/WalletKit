//
//  BitcoinClient+TransactionHistory.swift
//  WalletKit
//

import Foundation

/// `transactionHistory`/`transactionHeads` for ``BitcoinClient``. No new
/// `TransactionHistorySource` is needed for Bitcoin — both backends are
/// themselves address-indexed, so this alone satisfies the same role
/// ADR-005's pluggable history sources play for EVM/Sui.
extension BitcoinClient {
    /// Unions every discovered, used address's history from the backend,
    /// dedupes by txid, sorts by `(height, txid)` per `request.direction`
    /// (unconfirmed transactions sort as the newest), and hydrates the
    /// requested page via `backend.transaction(txid:)`.
    ///
    /// The cursor encodes the last emitted entry's `"height|txid"` as
    /// UTF-8 bytes; resuming re-unions and re-sorts before finding that
    /// position, so it stays correct even if new transactions have
    /// arrived since the previous page.
    public func transactionHistory(
        _ owner: BitcoinDescriptor,
        request: BlockchainTransactionHistoryRequest
    ) async throws -> BlockchainTransactionPage {
        // Captured before querying history so a block that arrives between
        // the two calls can't be skipped: without this, its transaction
        // would be absent from `entries` yet its height would become
        // `head`, and the next forward-sync page (`lowerBound: head + 1`)
        // would then permanently skip it. Bounding this page's entries by
        // `head` below defers any such transaction to the next sync instead.
        //
        // `request.upperBound`, once set, is the durable head snapshotted by
        // the first descending backfill page — every subsequent page must
        // keep returning that same value (mirroring Sui's `savedCursor?
        // .upperBound ?? request.upperBound ?? head`), or a block arriving
        // mid-backfill would advance `currentHead` past it on `commit` and
        // forward sync would permanently skip that block's transactions.
        let head = try await backend.currentHeight()
        let pageHead = request.upperBound ?? head

        let resolver = resolver(for: owner)
        let usedAddresses = try await resolver.allAddresses().filter(\.isUsed)

        var seenTxids = Set<String>()
        var entries: [BitcoinBackendHistoryEntry] = []
        for derived in usedAddresses {
            for entry in try await backend.history(of: derived.address) where seenTxids.insert(entry.txid).inserted {
                entries.append(entry)
            }
        }

        // `lowerBound`/`upperBound` are inclusive block-height bounds — the
        // ascending forward-sync track sets `lowerBound: currentHead + 1`
        // precisely so it never re-considers already-synced history; without
        // filtering here, every call would re-union entries all the way back
        // to genesis and rely on the cursor alone to skip them. An
        // unconfirmed entry (`height == nil`) has no height to compare, so
        // it always passes — same as how the sort below treats it as the
        // newest entry, since it's still pending activity either track
        // should surface. `pageHead` additionally caps every branch so a
        // block mined after the snapshot above (or after the initial
        // backfill snapshot, for later descending pages) is deferred rather
        // than included.
        entries = entries.filter { entry in
            guard let height = entry.height else {
                return true
            }

            if height > pageHead {
                return false
            }

            if let lowerBound = request.lowerBound, height < lowerBound {
                return false
            }

            return true
        }

        let ascending = request.direction == .ascending
        entries.sort { lhs, rhs in
            switch (lhs.height, rhs.height) {
            case let (leftHeight?, rightHeight?):
                return ascending ? leftHeight < rightHeight : leftHeight > rightHeight
            case (nil, nil):
                return lhs.txid < rhs.txid
            case (nil, _):
                return !ascending // unconfirmed sorts as the newest.
            case (_, nil):
                return ascending
            }
        }

        var startIndex = 0
        if let cursor = request.cursor, let cursorPosition = String(data: cursor, encoding: .utf8) {
            if let matchIndex = entries.firstIndex(where: { Self.cursorPosition(for: $0) == cursorPosition }) {
                startIndex = matchIndex + 1
            }
        }

        let page = Array(entries[min(startIndex, entries.count)...].prefix(Int(request.limit)))
        let ownedScripts = Set(usedAddresses.map { $0.address.scriptPubkey() })

        var transactions: [BlockchainTransaction] = []
        for entry in page {
            transactions.append(try await hydrate(entry, owner: owner, ownedScripts: ownedScripts))
        }

        let reachedBoundary = startIndex + page.count >= entries.count
        let nextCursor = page.last.flatMap { Data(Self.cursorPosition(for: $0).utf8) }

        // `TransactionSyncService` needs `head` to establish `currentHead`
        // and start forward polling — the same role `eth_blockNumber`/
        // `GetServiceInfo.checkpointHeight` play for Ethereum/Sui. Without
        // it, Bitcoin's forward sync stays stalled forever after backfill.
        return BlockchainTransactionPage(
            transactions: transactions,
            nextCursor: reachedBoundary ? nil : nextCursor,
            reachedBoundary: reachedBoundary,
            head: pageHead
        )
    }

    public nonisolated func transactionHeads(_ owner: BitcoinDescriptor) -> AsyncThrowingStream<BlockchainTransactionHead, any Swift.Error> {
        backend.headsStream()
    }

    // MARK: - Private

    private static func cursorPosition(for entry: BitcoinBackendHistoryEntry) -> String {
        "\(entry.height ?? 0)|\(entry.txid)"
    }

    /// Hydrates `entry` into a normalised ``BlockchainTransaction``,
    /// computing the net effect against `ownedScripts` — the sum of
    /// outputs paying one of our own addresses minus the sum of inputs
    /// spending from one of our own addresses.
    private func hydrate(
        _ entry: BitcoinBackendHistoryEntry,
        owner: BitcoinDescriptor,
        ownedScripts: Set<Data>
    ) async throws -> BlockchainTransaction {
        let transaction = try await backend.transaction(txid: entry.txid)

        let sentSats = transaction.inputs.filter { ownedScripts.contains($0.scriptPubkey) }.reduce(0) { $0 + $1.valueSats }
        let receivedSats = transaction.outputs.filter { ownedScripts.contains($0.scriptPubkey) }.reduce(0) { $0 + $1.valueSats }
        let netSats = Int64(receivedSats) - Int64(sentSats)

        let effect = BlockchainTransactionEffect(
            index: 0,
            kind: .nativeTransfer,
            amount: String(abs(netSats)),
            from: netSats < 0 ? owner.string : nil,
            to: netSats > 0 ? owner.string : nil
        )

        return BlockchainTransaction(
            identifier: transaction.txid,
            blockHeight: entry.height,
            timestamp: transaction.blockTime,
            status: entry.height != nil ? .confirmed : .unconfirmed,
            effects: [effect]
        )
    }
}
