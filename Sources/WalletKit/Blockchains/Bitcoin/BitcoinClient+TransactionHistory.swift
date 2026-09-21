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
        let resolver = resolver(for: owner)
        let usedAddresses = try await resolver.allAddresses().filter(\.isUsed)

        var seenTxids = Set<String>()
        var entries: [BitcoinBackendHistoryEntry] = []
        for derived in usedAddresses {
            for entry in try await backend.history(of: derived.address) where seenTxids.insert(entry.txid).inserted {
                entries.append(entry)
            }
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

        return BlockchainTransactionPage(
            transactions: transactions,
            nextCursor: reachedBoundary ? nil : nextCursor,
            reachedBoundary: reachedBoundary
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
