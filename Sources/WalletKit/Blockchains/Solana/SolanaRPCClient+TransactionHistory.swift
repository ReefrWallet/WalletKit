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
    /// A wallet's history is spread across several signature lists — its
    /// own, plus one per SPL token account it owns — and
    /// `getSignaturesForAddress`'s
    /// `before`/`until` only accept signatures drawn from the list they
    /// are passed with. So every scanned address carries its own
    /// independent ``AddressCursor``, keyed by base-58 address.
    private struct Cursor: Codable {
        let addresses: [String: AddressCursor]
    }

    /// One scanned address's position within the scan in progress.
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
    /// - `drained`: `true` once this address has come back empty in the
    ///   current scan. Later pages of the same scan skip it instead of
    ///   re-requesting an exhausted list while the other addresses page
    ///   on.
    private struct AddressCursor: Codable {
        let before: String?
        let drained: Bool
        let pendingUntil: String?
        let until: String?
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

    /// Every address whose signature list makes up `owner`'s history:
    /// `owner` itself, plus each SPL token account it holds under either
    /// token program.
    ///
    /// A transfer *into* a token account that already exists names only
    /// that token account among the transaction's account keys — never
    /// `owner` — so scanning `owner`'s own list alone silently drops every
    /// incoming SPL transfer after the one that created the account (which
    /// does name `owner`, since creating an ATA passes its owner in). The
    /// two `getTokenAccountsByOwner` reads this costs per page are the
    /// price of catching them. A token account closed since it last
    /// received funds drops out of the scan — the node no longer reports
    /// it as owned.
    private func scannedAddresses(of owner: SolanaAddress) async throws -> [SolanaAddress] {
        var addresses = [owner]

        for program in [SolanaProgram.token, SolanaProgram.token2022] {
            addresses += try await tokenAccounts(of: owner, tokenProgram: program).map(\.tokenAccount)
        }

        var seen: Set<String> = []
        return addresses.filter { seen.insert($0.string).inserted }
    }

    /// Advances one address's scan state over the page it just returned.
    private func advance(
        _ state: AddressCursor?,
        over page: [SignatureInfo],
        direction: BlockchainTransactionScanDirection
    ) -> AddressCursor {
        // Newest-first, so the last entry is the oldest one this page saw
        // and becomes the next page's `before`.
        guard let newest = page.first?.signature, let oldest = page.last?.signature else {
            return AddressCursor(
                before: state?.before,
                drained: true,
                pendingUntil: state?.pendingUntil,
                until: state?.until
            )
        }

        switch direction {
        case .ascending:
            return AddressCursor(
                before: oldest,
                drained: false,
                pendingUntil: state?.pendingUntil ?? newest,
                until: state?.until
            )
        case .descending:
            return AddressCursor(before: oldest, drained: false, pendingUntil: nil, until: nil)
        }
    }

    /// Makes `state` the starting point of the *next* forward pass: its
    /// pending boundary becomes durable, and the address is re-armed for
    /// that pass.
    private func promoted(_ state: AddressCursor) -> AddressCursor {
        AddressCursor(before: nil, drained: false, pendingUntil: nil, until: state.pendingUntil ?? state.until)
    }

    /// Requests one page of signatures from every address still live in
    /// this scan — skipping the ones already drained — and reports the
    /// state each of them advances to.
    private func signaturePages(
        of owner: SolanaAddress,
        cursor: Cursor?,
        request: BlockchainTransactionHistoryRequest
    ) async throws -> (signatures: [SignatureInfo], states: [String: AddressCursor]) {
        var signatures: [SignatureInfo] = []
        var states: [String: AddressCursor] = [:]

        for address in try await scannedAddresses(of: owner) {
            let state = cursor?.addresses[address.string]

            guard !(state?.drained ?? false) else {
                states[address.string] = state
                continue
            }

            let page = try await signaturesForAddress(
                address,
                limit: request.limit,
                before: state?.before,
                until: request.direction == .ascending ? state?.until : nil
            )

            states[address.string] = advance(state, over: page, direction: request.direction)
            signatures += page
        }

        return (signatures, states)
    }

    /// Returns one page of `owner`'s transaction history, merged across
    /// every discovered address — so a page can carry up
    /// to `request.limit` signatures *per scanned address*.
    ///
    /// - Descending (backfill): pages backward from the chain tip (or
    ///   `request.cursor`) toward genesis via `before`; `reachedBoundary`
    ///   is `true` once every address has come back empty.
    /// - Ascending (forward catch-up): pages toward the tip, bounded
    ///   below by the durable per-address `until` boundary carried in
    ///   `request.cursor`; `reachedBoundary` is `true` once the gap since
    ///   those boundaries is fully drained, at which point each boundary
    ///   advances to the newest signature that address saw.
    public func transactionHistory(
        _ owner: SolanaAddress,
        request: BlockchainTransactionHistoryRequest
    ) async throws -> BlockchainTransactionPage {
        let cursor = request.cursor.flatMap { try? JSONDecoder().decode(Cursor.self, from: $0) }
        let (signatures, states) = try await signaturePages(of: owner, cursor: cursor, request: request)

        // One transaction usually appears in both the wallet's own list and
        // its token account's, so the merged lists overlap.
        var seen: Set<String> = []
        let merged = signatures
            .filter { seen.insert($0.signature).inserted }
            .sorted { $0.slot > $1.slot }

        var transactions: [BlockchainTransaction] = []
        for info in merged {
            if let transaction = try await transaction(signature: info.signature, owner: owner) {
                transactions.append(transaction)
            }
        }

        let reachedBoundary = states.values.allSatisfy(\.drained)
        let nextCursor = reachedBoundary && request.direction == .ascending
            ? Cursor(addresses: states.mapValues(promoted))
            : Cursor(addresses: states)

        return BlockchainTransactionPage(
            transactions: transactions,
            nextCursor: try JSONEncoder().encode(nextCursor),
            reachedBoundary: reachedBoundary,
            head: merged.map(\.slot).max()
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
