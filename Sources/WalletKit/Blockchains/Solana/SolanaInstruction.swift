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
    private static let createAccountWithSeedDiscriminant: UInt32 = 3
    private static let transferDiscriminant: UInt32 = 2

    /// Builds a `CreateAccountWithSeed` instruction. `funder` pays `lamports`, signs and is also
    /// the seed's base, which is why no separate base account is listed. `created` must equal
    /// ``SolanaAddress/createWithSeed(base:seed:owner:)`` of `funder`, `seed` and `owner`.
    public static func createAccountWithSeed(
        funder: SolanaAddress,
        created: SolanaAddress,
        seed: String,
        lamports: UInt64,
        space: UInt64,
        owner: SolanaAddress
    ) -> SolanaInstruction {
        var data = Data()
        data.append(withUnsafeBytes(of: createAccountWithSeedDiscriminant.littleEndian) { Data($0) })
        data.append(funder.rawBytes)
        data.append(withUnsafeBytes(of: UInt64(seed.utf8.count).littleEndian) { Data($0) })
        data.append(Data(seed.utf8))
        data.append(withUnsafeBytes(of: lamports.littleEndian) { Data($0) })
        data.append(withUnsafeBytes(of: space.littleEndian) { Data($0) })
        data.append(owner.rawBytes)
        return SolanaInstruction(
            programId: SolanaProgram.system,
            accounts: [
                SolanaAccountMeta(address: funder, isSigner: true, isWritable: true),
                SolanaAccountMeta(address: created, isSigner: false, isWritable: true)
            ],
            data: data
        )
    }

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

// MARK: - Stake Program

/// Instruction builders for the native Stake program. Trezor shows its stake, unstake and claim
/// screens only for these exact account lists.
public enum StakeProgram {
    /// A stake account's size.
    public static let accountSize: UInt64 = 200

    private static let deactivateDiscriminant: UInt32 = 5
    private static let delegateDiscriminant: UInt32 = 2
    private static let initializeDiscriminant: UInt32 = 0
    private static let splitDiscriminant: UInt32 = 3
    private static let withdrawDiscriminant: UInt32 = 4

    /// Builds a `Deactivate` instruction, starting `stake`'s cooldown.
    public static func deactivate(stake: SolanaAddress, staker: SolanaAddress) -> SolanaInstruction {
        SolanaInstruction(
            programId: SolanaProgram.stake,
            accounts: [
                SolanaAccountMeta(address: stake, isSigner: false, isWritable: true),
                SolanaAccountMeta(address: SolanaProgram.sysvarClock, isSigner: false, isWritable: false),
                SolanaAccountMeta(address: staker, isSigner: true, isWritable: false)
            ],
            data: discriminant(deactivateDiscriminant)
        )
    }

    /// Builds a `DelegateStake` instruction, delegating `stake` to the vote account `voter`.
    public static func delegate(
        stake: SolanaAddress,
        voter: SolanaAddress,
        staker: SolanaAddress
    ) -> SolanaInstruction {
        SolanaInstruction(
            programId: SolanaProgram.stake,
            accounts: [
                SolanaAccountMeta(address: stake, isSigner: false, isWritable: true),
                SolanaAccountMeta(address: voter, isSigner: false, isWritable: false),
                SolanaAccountMeta(address: SolanaProgram.sysvarClock, isSigner: false, isWritable: false),
                SolanaAccountMeta(address: SolanaProgram.sysvarStakeHistory, isSigner: false, isWritable: false),
                SolanaAccountMeta(address: SolanaProgram.stakeConfig, isSigner: false, isWritable: false),
                SolanaAccountMeta(address: staker, isSigner: true, isWritable: false)
            ],
            data: discriminant(delegateDiscriminant)
        )
    }

    /// Builds an `Initialize` instruction (not `InitializeChecked`, which Trezor's stake screen
    /// doesn't recognize) with both authorities set to `authority`, and no lockup.
    public static func initialize(stake: SolanaAddress, authority: SolanaAddress) -> SolanaInstruction {
        var data = discriminant(initializeDiscriminant)
        data.append(authority.rawBytes)
        data.append(authority.rawBytes)
        data.append(Data(count: 16)) // Lockup: unix timestamp and epoch.
        data.append(SolanaProgram.system.rawBytes) // Lockup: custodian.
        return SolanaInstruction(
            programId: SolanaProgram.stake,
            accounts: [
                SolanaAccountMeta(address: stake, isSigner: false, isWritable: true),
                SolanaAccountMeta(address: SolanaProgram.sysvarRent, isSigner: false, isWritable: false)
            ],
            data: data
        )
    }

    /// Builds a `Split` instruction moving `lamports` of `source` into `destination`, which must
    /// already be allocated to the Stake program and rent-exempt.
    public static func split(
        source: SolanaAddress,
        destination: SolanaAddress,
        staker: SolanaAddress,
        lamports: UInt64
    ) -> SolanaInstruction {
        var data = discriminant(splitDiscriminant)
        data.append(withUnsafeBytes(of: lamports.littleEndian) { Data($0) })
        return SolanaInstruction(
            programId: SolanaProgram.stake,
            accounts: [
                SolanaAccountMeta(address: source, isSigner: false, isWritable: true),
                SolanaAccountMeta(address: destination, isSigner: false, isWritable: true),
                SolanaAccountMeta(address: staker, isSigner: true, isWritable: false)
            ],
            data: data
        )
    }

    /// Builds a `Withdraw` instruction moving `lamports` from `stake` to `recipient`.
    public static func withdraw(
        stake: SolanaAddress,
        recipient: SolanaAddress,
        withdrawer: SolanaAddress,
        lamports: UInt64
    ) -> SolanaInstruction {
        var data = discriminant(withdrawDiscriminant)
        data.append(withUnsafeBytes(of: lamports.littleEndian) { Data($0) })
        return SolanaInstruction(
            programId: SolanaProgram.stake,
            accounts: [
                SolanaAccountMeta(address: stake, isSigner: false, isWritable: true),
                SolanaAccountMeta(address: recipient, isSigner: false, isWritable: true),
                SolanaAccountMeta(address: SolanaProgram.sysvarClock, isSigner: false, isWritable: false),
                SolanaAccountMeta(address: SolanaProgram.sysvarStakeHistory, isSigner: false, isWritable: false),
                SolanaAccountMeta(address: withdrawer, isSigner: true, isWritable: false)
            ],
            data: data
        )
    }

    private static func discriminant(_ value: UInt32) -> Data {
        withUnsafeBytes(of: value.littleEndian) { Data($0) }
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
    /// µLamports per compute unit, validators are paid on top of the
    /// base fee to prioritize this transaction.
    public static func setComputeUnitPrice(microLamports: UInt64) -> SolanaInstruction {
        var data = Data([setComputeUnitPriceDiscriminant])
        data.append(withUnsafeBytes(of: microLamports.littleEndian) { Data($0) })
        return SolanaInstruction(programId: SolanaProgram.computeBudget, accounts: [], data: data)
    }
}
