//
//  SolanaProgram.swift
//  WalletKit
//
//  Created by Andrey Yurkevich on 21/09/2026.
//  Copyright © 2026 Reefr Wallet. All rights reserved.
//

import Foundation
import WalletKitRust

/// Well-known Solana program addresses, and the two program-derived
/// addresses (PDAs) WalletKit computes directly: a wallet's associated
/// token account (ATA) and a mint's Metaplex Token Metadata account.
public enum SolanaProgram {
    /// Transfers native SOL and creates/assigns/allocates accounts.
    public static let system = try! SolanaAddress(string: "11111111111111111111111111111111")

    /// The classic SPL Token program.
    public static let token = try! SolanaAddress(string: "TokenkegQfeZyiNwAJbNbGKPFXCWuBvf9Ss623VQ5DA")

    /// Token-2022 — the SPL Token program's extensible successor.
    public static let token2022 = try! SolanaAddress(string: "TokenzQdBNbLqP5VEhdkAS6EPFLC1PHnBqCXEpPxuEb")

    /// Derives and (idempotently) creates associated token accounts.
    public static let associatedToken = try! SolanaAddress(string: "ATokenGPvbdGVxr1b2hvZbsiqW5xWH25efTNsLJA8knL")

    /// Sets per-transaction compute-unit price/limit.
    public static let computeBudget = try! SolanaAddress(string: "ComputeBudget111111111111111111111111111111")

    /// Metaplex's Token Metadata program — stores a mint's on-chain
    /// name/symbol/URI.
    public static let tokenMetadata = try! SolanaAddress(string: "metaqbxxUerdq28cj1RbAWkYQm3ybzjb6a8bt518x1s")

    /// Derives `owner`'s associated token account (ATA) for `mint` under
    /// `tokenProgram` — the PDA of `[owner, tokenProgram, mint]` under
    /// ``associatedToken``.
    ///
    /// - Parameters:
    ///   - owner: The wallet address the ATA belongs to.
    ///   - mint: The token mint address.
    ///   - tokenProgram: The token program `mint` belongs to — ``token``
    ///     or ``token2022``.
    public static func associatedTokenAddress(
        owner: SolanaAddress,
        mint: SolanaAddress,
        tokenProgram: SolanaAddress = SolanaProgram.token
    ) throws -> SolanaAddress {
        let raw = try remappingWalletKitError {
            try solanaAssociatedTokenAddress(
                owner: owner.rawBytes, mint: mint.rawBytes, tokenProgram: tokenProgram.rawBytes
            )
        }
        return try SolanaAddress(rawBytes: raw)
    }

    /// Derives `mint`'s Metaplex Token Metadata account — the PDA of
    /// `["metadata", tokenMetadata, mint]` under ``tokenMetadata``.
    ///
    /// - Parameter mint: The token mint address.
    public static func metadataAddress(mint: SolanaAddress) throws -> SolanaAddress {
        let raw = try remappingWalletKitError { try solanaMetadataAddress(mint: mint.rawBytes) }
        return try SolanaAddress(rawBytes: raw)
    }
}
