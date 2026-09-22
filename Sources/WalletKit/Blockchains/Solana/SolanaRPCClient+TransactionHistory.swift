//
//  SolanaRPCClient+TransactionHistory.swift
//  WalletKit
//
//  Created by Andrey Yurkevich on 21/09/2026.
//  Copyright © 2026 Reefr Wallet. All rights reserved.
//

import BigInt
import Foundation

extension SolanaRPCClient {
    /// The opaque cursor ``transactionHistory(_:request:)`` persists
    /// between pages.
    ///
    /// - `before`: this page's continuation pointer within the current
    ///   scan — `getSignaturesForAddress`'s `before` param.
    /// - `until`: the durable boundary a forward (ascending) scan won't
    ///   cross — everything at or older than this signature was already
    ///   seen on a previous call. `nil` for a descending (backfill) scan,
    ///   which always goes all the way to genesis.
    /// - `pendingUntil`: the newest signature observed at the *start* of
    ///   the ascending scan currently in progress — carried through every
    ///   continuation page and promoted to `until` once the scan drains
    ///   (an empty page comes back), since `getSignaturesForAddress`
    ///   only ever reports the newest signature on the first page of a
    ///   multi-page gap.
    private struct Cursor: Codable {
        let before: String?
        let until: String?
        let pendingUntil: String?
    }

    private struct SignaturesForAddressParams: Encodable {
        let address: String
        let limit: UInt32
        let before: String?
        let until: String?

        private struct Config: Encodable {
            let limit: UInt32
            let before: String?
            let until: String?
            // Not the RPC default `finalized` — see `SolanaRPCClient`'s
            // other reads for why that lags a just-broadcast transaction.
            let commitment = "confirmed"
        }

        func encode(to encoder: Encoder) throws {
            var container = encoder.unkeyedContainer()
            try container.encode(address)
            try container.encode(Config(limit: limit, before: before, until: until))
        }
    }

    private struct SignatureInfo: Decodable {
        let signature: String
        let slot: UInt64
        let err: JSONValue?
    }

    /// Returns one page of signatures for `owner` — `getSignaturesForAddress`
    /// — newest-first, strictly between `before` (exclusive, older bound)
    /// and `until` (exclusive, newer bound).
    private func signaturesForAddress(
        _ owner: SolanaAddress,
        limit: UInt32,
        before: String?,
        until: String?
    ) async throws -> [SignatureInfo] {
        try await rpc.call(
            method: "getSignaturesForAddress",
            params: SignaturesForAddressParams(address: owner.string, limit: limit, before: before, until: until)
        )
    }

    private struct TransactionAccountKey: Decodable {
        let pubkey: String
        let signer: Bool
    }

    private struct TransactionMessage: Decodable {
        let accountKeys: [TransactionAccountKey]
    }

    private struct TransactionEnvelope: Decodable {
        let message: TransactionMessage
    }

    private struct TokenBalanceEntry: Decodable {
        let mint: String
        let owner: String?
        let uiTokenAmount: TokenAmountRaw

        struct TokenAmountRaw: Decodable {
            let amount: String
        }
    }

    private struct TransactionMeta: Decodable {
        let err: JSONValue?
        let fee: UInt64
        let preBalances: [UInt64]
        let postBalances: [UInt64]
        let preTokenBalances: [TokenBalanceEntry]?
        let postTokenBalances: [TokenBalanceEntry]?
    }

    private struct GetTransactionParams: Encodable {
        let signature: String

        private struct Config: Encodable {
            let encoding = "jsonParsed"
            let maxSupportedTransactionVersion = 0
            // Matches `getSignaturesForAddress`'s `confirmed` commitment
            // above — `getTransaction` only accepts `confirmed`/
            // `finalized` (no `processed`), and defaults to `finalized`.
            let commitment = "confirmed"
        }

        func encode(to encoder: Encoder) throws {
            var container = encoder.unkeyedContainer()
            try container.encode(signature)
            try container.encode(Config())
        }
    }

    private struct TransactionResponse: Decodable {
        let slot: UInt64
        let blockTime: Int64?
        let transaction: TransactionEnvelope
        let meta: TransactionMeta?
    }

    /// Fetches full transaction detail for `signature` and normalizes it
    /// relative to `owner`: a `.balanceChange` effect for the net lamport
    /// delta (deliberately not "transfer" semantics — the fee payer's
    /// balance already nets the network fee, so a clean sender/recipient
    /// split isn't recoverable from balances alone) plus one
    /// `.tokenTransfer` effect per SPL mint whose balance changed for an
    /// associated token account `owner` holds.
    private func transaction(signature: String, owner: SolanaAddress) async throws -> BlockchainTransaction? {
        let response: TransactionResponse? = try? await rpc.call(
            method: "getTransaction",
            params: GetTransactionParams(signature: signature)
        )
        guard let response else {
            return nil
        }

        let timestamp = response.blockTime.map { Date(timeIntervalSince1970: TimeInterval($0)) }
        let status: BlockchainTransactionStatus = (response.meta?.err == nil) ? .confirmed : .failed

        var effects: [BlockchainTransactionEffect] = []
        if let meta = response.meta,
           let ownerIndex = response.transaction.message.accountKeys.firstIndex(where: { $0.pubkey == owner.string }),
           ownerIndex < meta.preBalances.count, ownerIndex < meta.postBalances.count {
            let delta = Int64(meta.postBalances[ownerIndex]) - Int64(meta.preBalances[ownerIndex])
            if delta != 0 {
                effects.append(BlockchainTransactionEffect(index: 0, kind: .balanceChange, amount: "\(delta)"))
            }
        }

        if let meta = response.meta {
            let preByMint = Dictionary(
                (meta.preTokenBalances ?? []).filter { $0.owner == owner.string }.map { ($0.mint, $0) },
                uniquingKeysWith: { first, _ in first }
            )
            let postByMint = Dictionary(
                (meta.postTokenBalances ?? []).filter { $0.owner == owner.string }.map { ($0.mint, $0) },
                uniquingKeysWith: { first, _ in first }
            )
            for mint in Set(preByMint.keys).union(postByMint.keys) {
                let pre = BigUInt(preByMint[mint]?.uiTokenAmount.amount ?? "0") ?? 0
                let post = BigUInt(postByMint[mint]?.uiTokenAmount.amount ?? "0") ?? 0
                guard pre != post else { continue }
                let delta = post >= pre ? post - pre : pre - post
                effects.append(BlockchainTransactionEffect(
                    index: UInt64(effects.count),
                    kind: .tokenTransfer,
                    assetIdentifier: mint,
                    amount: "\(post >= pre ? "" : "-")\(delta)"
                ))
            }
        }

        return BlockchainTransaction(
            identifier: signature,
            blockHeight: response.slot,
            timestamp: timestamp,
            sender: response.transaction.message.accountKeys.first(where: \.signer)?.pubkey,
            status: status,
            effects: effects
        )
    }

    /// Returns one page of `owner`'s transaction history.
    ///
    /// - Descending (backfill): pages backward from the chain tip (or
    ///   `request.cursor`) toward genesis via `before`; `reachedBoundary`
    ///   is `true` once a page comes back empty.
    /// - Ascending (forward catch-up): pages toward the tip, bounded
    ///   below by the durable `until` boundary carried in
    ///   `request.cursor`; `reachedBoundary` is `true` once the gap since
    ///   that boundary is fully drained, at which point the boundary
    ///   advances to the newest signature seen.
    public func transactionHistory(
        _ owner: SolanaAddress,
        request: BlockchainTransactionHistoryRequest
    ) async throws -> BlockchainTransactionPage {
        let cursor = request.cursor.flatMap { try? JSONDecoder().decode(Cursor.self, from: $0) }
        let until = request.direction == .ascending ? cursor?.until : nil

        let signatures = try await signaturesForAddress(
            owner, limit: request.limit, before: cursor?.before, until: until
        )

        guard !signatures.isEmpty else {
            let nextCursor: Cursor
            switch request.direction {
            case .descending:
                nextCursor = cursor ?? Cursor(before: nil, until: nil, pendingUntil: nil)
            case .ascending:
                nextCursor = Cursor(before: nil, until: cursor?.pendingUntil ?? cursor?.until, pendingUntil: nil)
            }
            return BlockchainTransactionPage(
                transactions: [],
                nextCursor: try JSONEncoder().encode(nextCursor),
                reachedBoundary: true
            )
        }

        var transactions: [BlockchainTransaction] = []
        for info in signatures {
            if let transaction = try await transaction(signature: info.signature, owner: owner) {
                transactions.append(transaction)
            }
        }

        let newestSignature = signatures[0].signature
        let oldestSignature = signatures[signatures.count - 1].signature
        let head = signatures.map(\.slot).max()

        let nextCursor: Cursor
        switch request.direction {
        case .descending:
            nextCursor = Cursor(before: oldestSignature, until: nil, pendingUntil: nil)
        case .ascending:
            nextCursor = Cursor(
                before: oldestSignature,
                until: cursor?.until,
                pendingUntil: cursor?.pendingUntil ?? newestSignature
            )
        }

        return BlockchainTransactionPage(
            transactions: transactions,
            nextCursor: try JSONEncoder().encode(nextCursor),
            reachedBoundary: false,
            head: head
        )
    }
}

/// A minimal `Decodable` sink for a JSON value whose shape we don't care
/// about — used for `getTransaction`'s `meta.err`, which is `null` on
/// success and an arbitrarily-shaped error object on failure; only
/// presence/absence matters here.
struct JSONValue: Decodable {
    init(from decoder: Decoder) throws {
        _ = try decoder.singleValueContainer()
    }
}
