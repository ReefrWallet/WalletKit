//
//  SolanaMessage.swift
//  WalletKit
//
//  Created by Andrey Yurkevich on 21/09/2026.
//  Copyright © 2026 Reefr Wallet. All rights reserved.
//

import Foundation

/// The three account-privilege counts a legacy `Message` needs to let a
/// verifier recover every account's signer/writable flags purely from
/// its position in ``SolanaMessage/accountKeys`` — no per-account flag
/// bytes travel on the wire.
public struct SolanaMessageHeader: Equatable, Sendable {
    public let numRequiredSignatures: UInt8
    public let numReadonlySignedAccounts: UInt8
    public let numReadonlyUnsignedAccounts: UInt8
}

/// One instruction as it appears inside a compiled `Message` — accounts
/// referenced by index into ``SolanaMessage/accountKeys`` rather than by
/// address.
public struct SolanaCompiledInstruction: Equatable, Sendable {
    public let programIdIndex: UInt8
    public let accountIndexes: [UInt8]
    public let data: Data
}

/// A legacy Solana `Message` — the transaction body that gets signed and
/// broadcast directly, with no separate signing-hash step.
///
/// Account ordering follows Solana's own legacy-message rule: every
/// account referenced by any instruction (deduplicated) is bucketed into
/// four tiers, most-privileged first — writable signers, readonly
/// signers, writable non-signers, readonly non-signers — with the fee
/// payer forced into the first tier and first position. A verifier
/// reconstructs each account's signer/writable flags purely from its
/// position plus ``header``, without any per-account flag byte on the
/// wire.
public struct SolanaMessage: Equatable, Sendable {
    public let header: SolanaMessageHeader
    public let accountKeys: [SolanaAddress]
    public let recentBlockhash: Data
    public let instructions: [SolanaCompiledInstruction]

    public init(
        header: SolanaMessageHeader,
        accountKeys: [SolanaAddress],
        recentBlockhash: Data,
        instructions: [SolanaCompiledInstruction]
    ) {
        self.header = header
        self.accountKeys = accountKeys
        self.recentBlockhash = recentBlockhash
        self.instructions = instructions
    }

    /// Compiles `instructions` into a legacy `Message`.
    ///
    /// - Parameters:
    ///   - payer: The fee payer — forced into ``accountKeys``[0], signer
    ///     and writable, regardless of whether any instruction already
    ///     references it.
    ///   - instructions: The instructions to include, in order.
    ///   - recentBlockhash: A recent blockhash (32 bytes) the cluster
    ///     will accept as fresh.
    /// - Throws: ``WalletKitError/internalError(message:)`` if
    ///   `recentBlockhash` isn't 32 bytes, or if account/instruction
    ///   counts overflow the wire format's 8-bit/16-bit fields.
    public static func compile(
        payer: SolanaAddress,
        instructions: [SolanaInstruction],
        recentBlockhash: Data
    ) throws -> SolanaMessage {
        guard recentBlockhash.count == 32 else {
            throw WalletKitError.internalError(
                message: "Solana recentBlockhash must be 32 bytes, got \(recentBlockhash.count)"
            )
        }

        var order: [SolanaAddress] = []
        var metaByAddress: [Data: (isSigner: Bool, isWritable: Bool)] = [:]

        func upsert(_ address: SolanaAddress, isSigner: Bool, isWritable: Bool) {
            if let existing = metaByAddress[address.rawBytes] {
                metaByAddress[address.rawBytes] = (existing.isSigner || isSigner, existing.isWritable || isWritable)
            } else {
                metaByAddress[address.rawBytes] = (isSigner, isWritable)
                order.append(address)
            }
        }

        upsert(payer, isSigner: true, isWritable: true)
        for instruction in instructions {
            for account in instruction.accounts {
                upsert(account.address, isSigner: account.isSigner, isWritable: account.isWritable)
            }
            upsert(instruction.programId, isSigner: false, isWritable: false)
        }

        func priority(_ address: SolanaAddress) -> Int {
            let meta = metaByAddress[address.rawBytes]!
            switch (meta.isSigner, meta.isWritable) {
            case (true, true): return 0
            case (true, false): return 1
            case (false, true): return 2
            case (false, false): return 3
            }
        }

        // `sorted` is stable, so accounts that land in the same tier keep
        // their first-seen order — `payer` was inserted first, so it's
        // guaranteed to stay at index 0 within tier 0.
        let accountKeys = order.sorted { priority($0) < priority($1) }

        guard accountKeys.count <= 255 else {
            throw WalletKitError.internalError(message: "Solana message references more than 255 accounts")
        }

        var indexByAddress: [Data: UInt8] = [:]
        for (index, address) in accountKeys.enumerated() {
            indexByAddress[address.rawBytes] = UInt8(index)
        }

        let numRequiredSignatures = accountKeys.filter { metaByAddress[$0.rawBytes]!.isSigner }.count
        let numReadonlySignedAccounts = accountKeys.filter {
            let meta = metaByAddress[$0.rawBytes]!
            return meta.isSigner && !meta.isWritable
        }.count
        let numReadonlyUnsignedAccounts = accountKeys.filter {
            let meta = metaByAddress[$0.rawBytes]!
            return !meta.isSigner && !meta.isWritable
        }.count

        guard numRequiredSignatures <= 255, numReadonlySignedAccounts <= 255, numReadonlyUnsignedAccounts <= 255 else {
            throw WalletKitError.internalError(message: "Solana message account-privilege counts overflow a byte")
        }

        let compiledInstructions = try instructions.map { instruction -> SolanaCompiledInstruction in
            guard instruction.accounts.count <= 255 else {
                throw WalletKitError.internalError(message: "Solana instruction references more than 255 accounts")
            }
            return SolanaCompiledInstruction(
                programIdIndex: indexByAddress[instruction.programId.rawBytes]!,
                accountIndexes: instruction.accounts.map { indexByAddress[$0.address.rawBytes]! },
                data: instruction.data
            )
        }

        return SolanaMessage(
            header: SolanaMessageHeader(
                numRequiredSignatures: UInt8(numRequiredSignatures),
                numReadonlySignedAccounts: UInt8(numReadonlySignedAccounts),
                numReadonlyUnsignedAccounts: UInt8(numReadonlyUnsignedAccounts)
            ),
            accountKeys: accountKeys,
            recentBlockhash: recentBlockhash,
            instructions: compiledInstructions
        )
    }

    /// The wire-format bytes of this message — exactly what gets signed
    /// (directly, with no hashing step) and, prefixed by the signature
    /// list, broadcast.
    public func serialize() -> Data {
        var data = Data()
        data.append(header.numRequiredSignatures)
        data.append(header.numReadonlySignedAccounts)
        data.append(header.numReadonlyUnsignedAccounts)
        data.append(SolanaShortVec.encode(accountKeys.count))
        for key in accountKeys {
            data.append(key.rawBytes)
        }
        data.append(recentBlockhash)
        data.append(SolanaShortVec.encode(instructions.count))
        for instruction in instructions {
            data.append(instruction.programIdIndex)
            data.append(SolanaShortVec.encode(instruction.accountIndexes.count))
            data.append(contentsOf: instruction.accountIndexes)
            data.append(SolanaShortVec.encode(instruction.data.count))
            data.append(instruction.data)
        }
        return data
    }

    /// Parses a legacy `Message`'s wire-format bytes, as produced by
    /// ``serialize()``.
    ///
    /// - Throws: ``WalletKitError/internalError(message:)`` if `data` is
    ///   truncated or malformed.
    public init(serialized data: Data) throws {
        func fail(_ message: String) -> WalletKitError {
            .internalError(message: "Solana message: \(message)")
        }

        guard data.count >= 3 else {
            throw fail("too short for a header")
        }
        var offset = 0
        let numRequiredSignatures = data[offset]; offset += 1
        let numReadonlySignedAccounts = data[offset]; offset += 1
        let numReadonlyUnsignedAccounts = data[offset]; offset += 1

        let accountKeyCount = try SolanaShortVec.decode(data, offset: &offset)
        var accountKeys: [SolanaAddress] = []
        for _ in 0..<accountKeyCount {
            guard offset + 32 <= data.count else { throw fail("truncated account key") }
            accountKeys.append(try SolanaAddress(rawBytes: Data(data[offset..<(offset + 32)])))
            offset += 32
        }

        guard offset + 32 <= data.count else { throw fail("truncated recent blockhash") }
        let recentBlockhash = Data(data[offset..<(offset + 32)])
        offset += 32

        let instructionCount = try SolanaShortVec.decode(data, offset: &offset)
        var instructions: [SolanaCompiledInstruction] = []
        for _ in 0..<instructionCount {
            guard offset < data.count else { throw fail("truncated instruction") }
            let programIdIndex = data[offset]; offset += 1

            let accountIndexCount = try SolanaShortVec.decode(data, offset: &offset)
            guard offset + accountIndexCount <= data.count else { throw fail("truncated instruction accounts") }
            let accountIndexes = Array(data[offset..<(offset + accountIndexCount)])
            offset += accountIndexCount

            let dataLength = try SolanaShortVec.decode(data, offset: &offset)
            guard offset + dataLength <= data.count else { throw fail("truncated instruction data") }
            let instructionData = Data(data[offset..<(offset + dataLength)])
            offset += dataLength

            instructions.append(SolanaCompiledInstruction(
                programIdIndex: programIdIndex, accountIndexes: accountIndexes, data: instructionData
            ))
        }

        header = SolanaMessageHeader(
            numRequiredSignatures: numRequiredSignatures,
            numReadonlySignedAccounts: numReadonlySignedAccounts,
            numReadonlyUnsignedAccounts: numReadonlyUnsignedAccounts
        )
        self.accountKeys = accountKeys
        self.recentBlockhash = recentBlockhash
        self.instructions = instructions
    }
}
