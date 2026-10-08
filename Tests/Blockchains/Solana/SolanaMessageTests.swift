import BigInt
import Foundation
import Testing
@testable import WalletKit

struct SolanaMessageTests {
    private func address(_ byte: UInt8) throws -> SolanaAddress {
        try SolanaAddress(rawBytes: Data(repeating: byte, count: 32))
    }

    @Test func compileOrdersAccountsByPrivilegeTierWithPayerFirst() throws {
        let payer = try address(1)
        let recipient = try address(2)
        let blockhash = Data(repeating: 9, count: 32)

        let message = try SolanaMessage.compile(
            payer: payer,
            instructions: [SystemProgram.transfer(from: payer, to: recipient, lamports: 1_000)],
            recentBlockhash: blockhash
        )

        // Tier order: writable signers (payer), readonly signers (none),
        // writable non-signers (recipient), readonly non-signers (System
        // Program, referenced only as the instruction's `programId`).
        #expect(message.accountKeys == [payer, recipient, SolanaProgram.system])
        #expect(message.header.numRequiredSignatures == 1)
        #expect(message.header.numReadonlySignedAccounts == 0)
        #expect(message.header.numReadonlyUnsignedAccounts == 1)

        let instruction = try #require(message.instructions.first)
        #expect(instruction.programIdIndex == 2)
        #expect(instruction.accountIndexes == [0, 1])
    }

    @Test func compileMergesPrivilegesForAnAccountReferencedTwice() throws {
        let payer = try address(1)
        let mint = try address(2)
        let sourceATA = try address(3)
        let destinationATA = try address(4)
        let owner = payer // sender pays and owns the source ATA

        // `createIdempotent` references `payer` as writable-signer (the
        // funder) and the ATA program references appear read-only; the
        // subsequent `transferChecked` references `owner` (== `payer`)
        // as a read-only signer. The merged privilege for `payer` must
        // stay writable+signer (the maximum across both instructions),
        // not be downgraded by the second reference.
        let instructions = [
            AssociatedTokenProgram.createIdempotent(
                payer: payer, associatedAccount: destinationATA, owner: try address(5), mint: mint,
                tokenProgram: SolanaProgram.token
            ),
            TokenProgram.transferChecked(
                source: sourceATA, mint: mint, destination: destinationATA, owner: owner,
                amount: 500, decimals: 6, tokenProgram: SolanaProgram.token
            )
        ]

        let message = try SolanaMessage.compile(
            payer: payer,
            instructions: instructions,
            recentBlockhash: Data(repeating: 0, count: 32)
        )

        let payerIndex = try #require(message.accountKeys.firstIndex(of: payer))
        #expect(payerIndex == 0)
        #expect(payerIndex < message.header.numRequiredSignatures)

        // A writable-signer account (tier 0) must never fall inside the
        // readonly-signer/readonly-unsigned tiers.
        let requiredSignatures = Int(message.header.numRequiredSignatures)
        let readonlySignedAccounts = Int(message.header.numReadonlySignedAccounts)
        let writableSignerCount = requiredSignatures - readonlySignedAccounts
        #expect(payerIndex < writableSignerCount)
    }

    @Test func compileRejectsARecentBlockhashOfTheWrongLength() {
        #expect(throws: WalletKitError.self) {
            _ = try SolanaMessage.compile(
                payer: try address(1),
                instructions: [SystemProgram.transfer(from: try address(1), to: try address(2), lamports: 1)],
                recentBlockhash: Data(repeating: 0, count: 31)
            )
        }
    }

    @Test func serializeRoundTripsThroughDeserialize() throws {
        let payer = try address(1)
        let recipient = try address(2)
        let instructions = [
            ComputeBudgetProgram.setComputeUnitPrice(microLamports: 1_000),
            SystemProgram.transfer(from: payer, to: recipient, lamports: 42)
        ]
        let message = try SolanaMessage.compile(
            payer: payer, instructions: instructions, recentBlockhash: Data(repeating: 7, count: 32)
        )

        let serialized = message.serialize()
        let decoded = try SolanaMessage(serialized: serialized)

        #expect(decoded.header == message.header)
        #expect(decoded.accountKeys == message.accountKeys)
        #expect(decoded.recentBlockhash == message.recentBlockhash)
        #expect(decoded.instructions == message.instructions)
        #expect(decoded.serialize() == serialized)
    }

    @Test func computeBudgetInstructionReferencesNoAccounts() throws {
        let payer = try address(1)
        let message = try SolanaMessage.compile(
            payer: payer,
            instructions: [ComputeBudgetProgram.setComputeUnitLimit(200_000)],
            recentBlockhash: Data(repeating: 0, count: 32)
        )

        let instruction = try #require(message.instructions.first)
        #expect(instruction.accountIndexes.isEmpty)
        // `setComputeUnitLimit`'s discriminant (2) + a little-endian u32.
        #expect(instruction.data == Data([2, 0x40, 0x0D, 0x03, 0x00]))
    }

    @Test func systemTransferInstructionDataMatchesTheKnownWireLayout() throws {
        let instruction = SystemProgram.transfer(from: try address(1), to: try address(2), lamports: 1)
        // 4-byte LE discriminant (2 == Transfer) + 8-byte LE lamports.
        #expect(instruction.data == Data([2, 0, 0, 0, 1, 0, 0, 0, 0, 0, 0, 0]))
    }

    @Test func transferCheckedInstructionDataMatchesTheKnownWireLayout() throws {
        let instruction = TokenProgram.transferChecked(
            source: try address(1), mint: try address(2), destination: try address(3), owner: try address(4),
            amount: 256, decimals: 6, tokenProgram: SolanaProgram.token
        )

        // 1-byte discriminant (12 == TransferChecked) + 8-byte LE amount + 1-byte decimals.
        #expect(instruction.data == Data([12, 0, 1, 0, 0, 0, 0, 0, 0, 6]))
    }

    @Test func createIdempotentInstructionDataIsASingleDiscriminantByte() throws {
        let instruction = AssociatedTokenProgram.createIdempotent(
            payer: try address(1), associatedAccount: try address(2), owner: try address(3), mint: try address(4),
            tokenProgram: SolanaProgram.token
        )
        #expect(instruction.data == Data([1]))
        #expect(instruction.accounts.count == 6)
    }
}
