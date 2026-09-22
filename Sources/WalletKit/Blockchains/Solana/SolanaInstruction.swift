//
//  SolanaInstruction.swift
//  WalletKit
//
//  Created by Andrey Yurkevich on 21/09/2026.
//  Copyright © 2026 Reefr Wallet. All rights reserved.
//

import Foundation

/// One account referenced by a ``SolanaInstruction`` — whether the
/// transaction's signature set must cover it, and whether the runtime
/// may write to it. Both flags are treated as the *minimum* privilege
/// this instruction needs; ``SolanaMessage/compile(payer:instructions:recentBlockhash:)``
/// takes the union across every instruction that references the same
/// address.
public struct SolanaAccountMeta: Equatable, Sendable {
    public let address: SolanaAddress
    public let isSigner: Bool
    public let isWritable: Bool

    public init(address: SolanaAddress, isSigner: Bool, isWritable: Bool) {
        self.address = address
        self.isSigner = isSigner
        self.isWritable = isWritable
    }
}

/// One instruction inside a Solana transaction: the program it invokes,
/// the accounts it reads/writes, and its program-specific instruction
/// data.
public struct SolanaInstruction: Equatable, Sendable {
    public let programId: SolanaAddress
    public let accounts: [SolanaAccountMeta]
    public let data: Data

    public init(programId: SolanaAddress, accounts: [SolanaAccountMeta], data: Data) {
        self.programId = programId
        self.accounts = accounts
        self.data = data
    }
}

// MARK: - System Program

/// Instruction builders for Solana's native System program.
public enum SystemProgram {
    private static let transferDiscriminant: UInt32 = 2

    /// Builds a `Transfer` instruction moving `lamports` of native SOL
    /// from `from` to `to`. `from` must sign the transaction.
    public static func transfer(from: SolanaAddress, to: SolanaAddress, lamports: UInt64) -> SolanaInstruction {
        var data = Data()
        data.append(withUnsafeBytes(of: transferDiscriminant.littleEndian) { Data($0) })
        data.append(withUnsafeBytes(of: lamports.littleEndian) { Data($0) })
        return SolanaInstruction(
            programId: SolanaProgram.system,
            accounts: [
                SolanaAccountMeta(address: from, isSigner: true, isWritable: true),
                SolanaAccountMeta(address: to, isSigner: false, isWritable: true)
            ],
            data: data
        )
    }
}

// MARK: - Token Program

/// Instruction builders shared by the SPL Token and Token-2022 programs —
/// both accept the same `TransferChecked` layout.
public enum TokenProgram {
    private static let transferCheckedDiscriminant: UInt8 = 12

    /// Builds a `TransferChecked` instruction moving `amount` of `mint`
    /// (at `decimals` significant digits) from `source` to `destination`,
    /// authorized by `owner`. `TransferChecked` is used instead of the
    /// older `Transfer` because it verifies `mint`/`decimals` on-chain,
    /// catching a wrong-decimals bug before it moves funds.
    ///
    /// - Parameters:
    ///   - source: The sender's token account (an ATA) for `mint`.
    ///   - mint: The token mint.
    ///   - destination: The recipient's token account (an ATA) for `mint`.
    ///   - owner: `source`'s owner; must sign the transaction.
    ///   - amount: The transfer amount, in the mint's smallest unit.
    ///   - decimals: `mint`'s decimal count, checked on-chain against the
    ///     mint account.
    ///   - tokenProgram: The token program `mint` belongs to —
    ///     ``SolanaProgram/token`` or ``SolanaProgram/token2022``.
    public static func transferChecked(
        source: SolanaAddress,
        mint: SolanaAddress,
        destination: SolanaAddress,
        owner: SolanaAddress,
        amount: UInt64,
        decimals: UInt8,
        tokenProgram: SolanaAddress
    ) -> SolanaInstruction {
        var data = Data([transferCheckedDiscriminant])
        data.append(withUnsafeBytes(of: amount.littleEndian) { Data($0) })
        data.append(decimals)
        return SolanaInstruction(
            programId: tokenProgram,
            accounts: [
                SolanaAccountMeta(address: source, isSigner: false, isWritable: true),
                SolanaAccountMeta(address: mint, isSigner: false, isWritable: false),
                SolanaAccountMeta(address: destination, isSigner: false, isWritable: true),
                SolanaAccountMeta(address: owner, isSigner: true, isWritable: false)
            ],
            data: data
        )
    }
}

// MARK: - Associated Token Account Program

/// Instruction builders for the SPL Associated Token Account program.
public enum AssociatedTokenProgram {
    /// `AssociatedTokenAccountInstruction::CreateIdempotent`'s discriminant.
    private static let createIdempotentDiscriminant: UInt8 = 1

    /// Builds a `CreateIdempotent` instruction: creates `associatedAccount`
    /// (the ATA for `owner`/`mint` under `tokenProgram`) if it doesn't
    /// already exist, and does nothing (no error) if it does — safe to
    /// prepend to every SPL transfer without a prior existence check.
    /// `payer` funds the account's rent and must sign.
    ///
    /// - Parameters:
    ///   - payer: Pays the new account's rent; must sign.
    ///   - associatedAccount: The ATA address to create — must equal
    ///     ``SolanaProgram/associatedTokenAddress(owner:mint:tokenProgram:)``
    ///     for `owner`/`mint`/`tokenProgram`, or the runtime rejects the
    ///     instruction.
    ///   - owner: The wallet the ATA is being created for.
    ///   - mint: The token mint the ATA holds a balance of.
    ///   - tokenProgram: The token program `mint` belongs to.
    public static func createIdempotent(
        payer: SolanaAddress,
        associatedAccount: SolanaAddress,
        owner: SolanaAddress,
        mint: SolanaAddress,
        tokenProgram: SolanaAddress
    ) -> SolanaInstruction {
        SolanaInstruction(
            programId: SolanaProgram.associatedToken,
            accounts: [
                SolanaAccountMeta(address: payer, isSigner: true, isWritable: true),
                SolanaAccountMeta(address: associatedAccount, isSigner: false, isWritable: true),
                SolanaAccountMeta(address: owner, isSigner: false, isWritable: false),
                SolanaAccountMeta(address: mint, isSigner: false, isWritable: false),
                SolanaAccountMeta(address: SolanaProgram.system, isSigner: false, isWritable: false),
                SolanaAccountMeta(address: tokenProgram, isSigner: false, isWritable: false)
            ],
            data: Data([createIdempotentDiscriminant])
        )
    }
}

// MARK: - Compute Budget Program

/// Instruction builders for the native Compute Budget program — neither
/// instruction references any account.
public enum ComputeBudgetProgram {
    private static let setComputeUnitLimitDiscriminant: UInt8 = 2
    private static let setComputeUnitPriceDiscriminant: UInt8 = 3

    /// Builds a `SetComputeUnitLimit` instruction capping this
    /// transaction's compute-unit budget at `units`.
    public static func setComputeUnitLimit(_ units: UInt32) -> SolanaInstruction {
        var data = Data([setComputeUnitLimitDiscriminant])
        data.append(withUnsafeBytes(of: units.littleEndian) { Data($0) })
        return SolanaInstruction(programId: SolanaProgram.computeBudget, accounts: [], data: data)
    }

    /// Builds a `SetComputeUnitPrice` instruction — the priority fee, in
    /// micro-lamports per compute unit, validators are paid on top of the
    /// base fee to prioritize this transaction.
    public static func setComputeUnitPrice(microLamports: UInt64) -> SolanaInstruction {
        var data = Data([setComputeUnitPriceDiscriminant])
        data.append(withUnsafeBytes(of: microLamports.littleEndian) { Data($0) })
        return SolanaInstruction(programId: SolanaProgram.computeBudget, accounts: [], data: data)
    }
}
