//
//  NFTConfirmation.swift
//  WalletKit
//
//  Copyright © 2026 Reefr Wallet. All rights reserved.
//

import Foundation

// MARK: - Solana

/// A signature's status and the slot it landed in.
public struct SolanaSignatureConfirmation: Equatable, Sendable {
    public let slot: UInt64?
    public let status: SolanaSignatureStatus
}

public extension SolanaRPCClient {
    /// `getSignatureStatuses` for one signature, with its slot.
    ///
    /// - Parameters:
    ///   - signature: The Base58 transaction signature.
    ///   - searchHistory: Whether the node searches its full ledger, not just
    ///     recent status caches.
    func signatureConfirmation(_ signature: String, searchHistory: Bool) async throws -> SolanaSignatureConfirmation {
        let response: SolanaRPCValue<[SignatureStatusEntry?]> = try await rpc.call(
            method: "getSignatureStatuses",
            params: SignatureStatusParams(signature: signature, searchHistory: searchHistory)
        )

        guard let entry = response.value.first ?? nil else {
            return SolanaSignatureConfirmation(slot: nil, status: .notFound)
        }

        let status: SolanaSignatureStatus = switch entry.confirmationStatus {
        case "confirmed", "finalized":
            entry.hasError ? .failed : .confirmed
        default:
            .processed
        }

        return SolanaSignatureConfirmation(slot: entry.slot, status: status)
    }
}

// MARK: - Cardano

/// A Cardano transaction's on-chain state, as Blockfrost reports it.
public struct CardanoTransactionConfirmation: Equatable, Sendable {
    public let slot: UInt64?
}

public extension CardanoClient {
    private struct TransactionInfo: Decodable {
        let slot: UInt64?
    }

    private struct LatestBlock: Decodable {
        let slot: UInt64?
    }

    /// The transaction's slot once Blockfrost has indexed it, or `nil`.
    func transactionConfirmation(_ hash: String) async throws -> CardanoTransactionConfirmation? {
        do {
            let info: TransactionInfo = try await get("txs/\(hash)")
            return CardanoTransactionConfirmation(slot: info.slot)
        } catch HTTPError.notFound {
            return nil
        }
    }

    /// Whether another transaction than `hash` consumed any of `inputs`.
    func isSpentByOtherTransaction(hash: String, inputs: [CardanoSpentInput]) async throws -> Bool {
        try await hasConflictingSpend(hash: hash, inputs: inputs)
    }

    /// The slot of Blockfrost's latest block.
    func tipSlot() async throws -> UInt64 {
        let block: LatestBlock = try await get("blocks/latest")

        guard let slot = block.slot else {
            throw BlockchainClientError.invalidResponse(reason: "latest block has no slot")
        }

        return slot
    }
}
