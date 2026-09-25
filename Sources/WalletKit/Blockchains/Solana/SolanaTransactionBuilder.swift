//
//  SolanaTransactionBuilder.swift
//  WalletKit
//
//  Created by Andrey Yurkevich on 21/09/2026.
//  Copyright © 2026 Reefr Wallet. All rights reserved.
//

import BigInt
import Foundation

/// A ``BlockchainTransactionBuilderProtocol`` implementation for Solana,
/// backed by a ``SolanaRPCClient``.
///
/// Builds a legacy ``SolanaMessage`` in a ``SolanaUnsignedTransaction``
/// envelope. SPL transfers include idempotent recipient associated-token
/// account creation when needed.
public struct SolanaTransactionBuilder: BlockchainTransactionBuilderProtocol {
    public typealias Address = SolanaAddress

    private let client: SolanaRPCClient

    /// Creates a builder backed by `client`.
    public init(client: SolanaRPCClient) {
        self.client = client
    }

    public func buildTransfer(
        sender: SolanaAddress,
        recipient: SolanaAddress,
        amount: BigUInt,
        token: String?,
        options: [BlockchainTransactionBuilderOptions]
    ) async throws -> Data {
        guard let amountU64 = UInt64(exactly: amount) else {
            throw BlockchainTransactionBuilderError.amountTooLarge
        }

        let priorityOverride = options.solanaPriorityFee
        let microLamportsPrice: UInt64
        if let overridden = priorityOverride?.microLamportsPerComputeUnit {
            microLamportsPrice = overridden
        } else {
            microLamportsPrice = try await client.recentPrioritizationFee()
        }

        var instructions: [SolanaInstruction] = [ComputeBudgetProgram.setComputeUnitPrice(microLamports: microLamportsPrice)]
        if let limit = priorityOverride?.computeUnitLimit {
            instructions.append(ComputeBudgetProgram.setComputeUnitLimit(limit))
        }

        let tokenAccounts: [SolanaTokenAccountInfo]
        if token == nil || token == SolanaRPCClient.nativeMintPlaceholder.string {
            guard try await client.lamportBalance(of: sender) > amountU64 else {
                throw BlockchainTransactionBuilderError.insufficientFunds(
                    reason: "need \(amountU64) lamports + fees but \(sender.string) has less"
                )
            }
            instructions.append(SystemProgram.transfer(from: sender, to: recipient, lamports: amountU64))
            tokenAccounts = []
        } else {
            guard let token else {
                throw BlockchainTransactionBuilderError.invalidToken(reason: "missing mint address")
            }
            let mint = try SolanaAddress(string: token)
            let (decimals, tokenProgram) = try await client.mintInfo(of: mint)

            let source = try SolanaProgram.associatedTokenAddress(owner: sender, mint: mint, tokenProgram: tokenProgram)
            let destination = try SolanaProgram.associatedTokenAddress(
                owner: recipient, mint: mint, tokenProgram: tokenProgram
            )

            let owned = try await client.tokenAccounts(of: sender, tokenProgram: tokenProgram)
                .filter { $0.mint == mint }
                .reduce(BigUInt(0)) { $0 + $1.amount }
            guard owned >= amount else {
                throw BlockchainTransactionBuilderError.insufficientFunds(
                    reason: "need \(amount) of \(token) but \(sender.string) only has \(owned)"
                )
            }

            instructions.append(AssociatedTokenProgram.createIdempotent(
                payer: sender, associatedAccount: destination, owner: recipient, mint: mint, tokenProgram: tokenProgram
            ))
            instructions.append(TokenProgram.transferChecked(
                source: source,
                mint: mint,
                destination: destination,
                owner: sender,
                amount: amountU64,
                decimals: decimals,
                tokenProgram: tokenProgram
            ))
            tokenAccounts = [
                SolanaTokenAccountInfo(
                    baseAddress: sender.string, tokenProgram: tokenProgram.string,
                    tokenMint: mint.string, tokenAccount: source.string
                ),
                SolanaTokenAccountInfo(
                    baseAddress: recipient.string, tokenProgram: tokenProgram.string,
                    tokenMint: mint.string, tokenAccount: destination.string
                )
            ]
        }

        let (blockhash, _) = try await client.latestBlockhash()
        let message = try SolanaMessage.compile(payer: sender, instructions: instructions, recentBlockhash: blockhash)
        let envelope = SolanaUnsignedTransaction(message: message.serialize(), tokenAccounts: tokenAccounts)
        return try JSONEncoder().encode(envelope)
    }
}

private extension [BlockchainTransactionBuilderOptions] {
    /// The `solanaPriorityFee` override, if any option in this array
    /// specifies one.
    var solanaPriorityFee: (microLamportsPerComputeUnit: UInt64?, computeUnitLimit: UInt32?)? {
        for option in self {
            if case let .solanaPriorityFee(microLamports, limit) = option {
                return (microLamports, limit)
            }
        }
        return nil
    }
}
