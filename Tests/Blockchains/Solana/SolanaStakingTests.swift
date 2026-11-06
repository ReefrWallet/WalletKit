// Tests of native staking's pure parts: Stake program instruction bytes (against the
// firmware's `sign_tx.staking_transactions.json`), seed addresses, the stake account layout,
// and transaction size limits.

import Foundation
import Testing
@testable import WalletKit

struct SolanaStakingTests {
    private let owner = SolanaAddress.known("14CCvQzQzHCVgZM3j9soPnXuJXh1RmCfwLVUcdfbZVBS")
    private let voter = SolanaAddress.known("ETxHeBBcuw9Yu4dGuP3oXrD12V5RECvmi8ogQ9PkjyVF")
    private let stake = SolanaAddress.known("ATFXMD5cYiw9yHkvexgx3nf9LNSouEViB5BZBsgwunAv")

    private func uint32(_ value: UInt32) -> Data {
        withUnsafeBytes(of: value.littleEndian) { Data($0) }
    }

    private func uint64(_ value: UInt64) -> Data {
        withUnsafeBytes(of: value.littleEndian) { Data($0) }
    }

    // MARK: Instructions

    @Test func createAccountWithSeedMatchesTheFirmwareFixture() {
        let instruction = SystemProgram.createAccountWithSeed(
            funder: owner,
            created: stake,
            seed: "seed:1",
            lamports: 20_000_000,
            space: 0,
            owner: SolanaProgram.stake
        )

        var expected = uint32(3)
        expected += owner.rawBytes
        expected += uint64(6) + Data("seed:1".utf8)
        expected += uint64(20_000_000) + uint64(0)
        expected += SolanaProgram.stake.rawBytes

        #expect(instruction.data == expected)
        #expect(instruction.programId == SolanaProgram.system)
        #expect(instruction.accounts.map(\.address) == [owner, stake])
        #expect(instruction.accounts.map(\.isSigner) == [true, false])
    }

    @Test func initializeUsesIdZeroWithNoLockupAndSystemCustodian() {
        let instruction = StakeProgram.initialize(stake: stake, authority: owner)

        let expected = uint32(0) + owner.rawBytes + owner.rawBytes + Data(count: 16) + SolanaProgram.system.rawBytes

        #expect(instruction.data == expected)
        #expect(instruction.accounts.map(\.address) == [stake, SolanaProgram.sysvarRent])
    }

    @Test func delegateListsTheSixAccountsTrezorExpects() {
        let instruction = StakeProgram.delegate(stake: stake, voter: voter, staker: owner)

        #expect(instruction.data == uint32(2))
        #expect(instruction.accounts.map(\.address) == [
            stake, voter, SolanaProgram.sysvarClock, SolanaProgram.sysvarStakeHistory, SolanaProgram.stakeConfig, owner
        ])
        #expect(instruction.accounts.filter(\.isSigner).map(\.address) == [owner])
    }

    @Test func deactivateListsThreeAccounts() {
        let instruction = StakeProgram.deactivate(stake: stake, staker: owner)

        #expect(instruction.data == uint32(5))
        #expect(instruction.accounts.map(\.address) == [stake, SolanaProgram.sysvarClock, owner])
    }

    @Test func splitCarriesTheLamports() {
        let instruction = StakeProgram.split(source: stake, destination: voter, staker: owner, lamports: 7)

        #expect(instruction.data == uint32(3) + uint64(7))
        #expect(instruction.accounts.map(\.address) == [stake, voter, owner])
    }

    @Test func withdrawListsFiveAccounts() {
        let instruction = StakeProgram.withdraw(stake: stake, recipient: owner, withdrawer: owner, lamports: 9)

        #expect(instruction.data == uint32(4) + uint64(9))
        #expect(instruction.accounts.map(\.address) == [
            stake, owner, SolanaProgram.sysvarClock, SolanaProgram.sysvarStakeHistory, owner
        ])
    }

    @Test func stakeMessageKeepsTheOrderTrezorMatches() throws {
        let instructions = try SolanaStakingTransactions.instructions(
            for: .stake(lamports: 5, voter: voter.string),
            owner: owner,
            created: ("stake:0", stake),
            rent: 2
        )

        #expect(instructions.map(\.programId) == [SolanaProgram.system, SolanaProgram.stake, SolanaProgram.stake])
        // Rent is on top of the amount, which is what Trezor's stake screen then shows.
        #expect(instructions[0].data.dropFirst(4 + 32 + 8 + 7).prefix(8) == uint64(7))
    }

    @Test func partialUnstakeFundsOnlyRentThenSplitsAndDeactivatesTheNewAccount() throws {
        let instructions = try SolanaStakingTransactions.instructions(
            for: .unstakePartial(account: voter.string, lamports: 5),
            owner: owner,
            created: ("stake:1", stake),
            rent: 2
        )

        #expect(instructions[0].data.dropFirst(4 + 32 + 8 + 7).prefix(8) == uint64(2))
        #expect(instructions[1].data == uint32(3) + uint64(5))
        #expect(instructions[2].accounts.first?.address == stake)
    }

    // MARK: Seed addresses

    /// The firmware's fixture uses this very address as its created stake account.
    @Test func seedAddressMatchesTheFirmwareFixture() throws {
        let address = try SolanaAddress.createWithSeed(base: owner, seed: "stake:0", owner: SolanaProgram.stake)
        #expect(address == stake)
    }

    @Test func seedsOver32BytesAreRefused() {
        #expect(throws: (any Error).self) {
            try SolanaAddress.createWithSeed(
                base: owner,
                seed: String(repeating: "x", count: 33),
                owner: SolanaProgram.stake
            )
        }
    }

    // MARK: Parser

    static func stakeAccountData(
        state: UInt32 = 2,
        staker: SolanaAddress,
        withdrawer: SolanaAddress,
        voter: SolanaAddress? = nil,
        stake: UInt64 = 0,
        activation: UInt64 = 0,
        deactivation: UInt64 = .max,
        lockupTimestamp: Int64 = 0,
        lockupEpoch: UInt64 = 0
    ) -> Data {
        func le<T: FixedWidthInteger>(_ value: T) -> Data {
            withUnsafeBytes(of: value.littleEndian) { Data($0) }
        }

        var data = le(state)
        data += le(UInt64(2_282_880))
        data += staker.rawBytes + withdrawer.rawBytes
        data += le(lockupTimestamp) + le(lockupEpoch) + SolanaProgram.system.rawBytes

        if let voter {
            data += voter.rawBytes
            data += le(stake) + le(activation) + le(deactivation)
        }

        data += Data(count: 200 - data.count)
        return data
    }

    @Test func parsesADelegatedAccount() throws {
        let data = Self.stakeAccountData(
            staker: owner,
            withdrawer: stake,
            voter: voter,
            stake: 123,
            activation: 4,
            deactivation: 9,
            lockupTimestamp: 77,
            lockupEpoch: 88
        )

        let account = try #require(SolanaStakeAccount(address: "x", lamports: 5, data: data))

        #expect(account.staker == owner.string)
        #expect(account.withdrawer == stake.string)
        #expect(account.rentExemptReserve == 2_282_880)
        #expect(account.lockup.unixTimestamp == 77)
        #expect(account.lockup.epoch == 88)
        #expect(account.delegation == .init(activationEpoch: 4, deactivationEpoch: 9, stake: 123, voter: voter.string))
    }

    @Test func parsesAnInitializedAccountWithoutDelegation() throws {
        let data = Self.stakeAccountData(state: 1, staker: owner, withdrawer: owner)
        let account = try #require(SolanaStakeAccount(address: "x", lamports: 5, data: data))

        #expect(account.delegation == nil)
    }

    @Test func refusesUninitializedAndShortAccounts() {
        #expect(SolanaStakeAccount(
            address: "x",
            lamports: 5,
            data: Self.stakeAccountData(state: 0, staker: owner, withdrawer: owner)
        ) == nil)
        #expect(SolanaStakeAccount(address: "x", lamports: 5, data: Data(count: 199)) == nil)
    }

    @Test func lockupBlocksUntilBothHavePassed() {
        let lockedByTime = lockup(timestamp: 100, epoch: 0)
        let lockedByEpoch = lockup(timestamp: 0, epoch: 10)
        let clock = SolanaClock(epoch: 5, epochStartTimestamp: 0, slot: 0, unixTimestamp: 50)

        #expect(lockedByTime.isLocked(at: clock))
        #expect(lockedByEpoch.isLocked(at: clock))
        #expect(!lockup(timestamp: 50, epoch: 5).isLocked(at: clock))
    }

    private func lockup(timestamp: Int64, epoch: UInt64) -> SolanaStakeAccount {
        SolanaStakeAccount(
            address: "x",
            delegation: nil,
            lamports: 0,
            lockup: .init(custodian: "", epoch: epoch, unixTimestamp: timestamp),
            rentExemptReserve: 0,
            staker: "",
            withdrawer: ""
        )
    }

    @Test func parsesTheStakeHistoryLayout() throws {
        var data = uint64(2)
        data += uint64(9) + uint64(100) + uint64(10) + uint64(1)
        data += uint64(8) + uint64(200) + uint64(20) + uint64(2)

        let history = try #require(SolanaStakeHistory(data: data))

        #expect(history.newestEpoch == 9)
        #expect(history.entry(9) == .init(activating: 10, deactivating: 1, effective: 100))
        #expect(history.entry(8) == .init(activating: 20, deactivating: 2, effective: 200))
        #expect(history.entry(7) == nil)
    }

    // MARK: Transaction size

    @Test func exactLimitFitsAndOneByteOverDoesNot() {
        // Signature count prefix (1) + one signature (64) + message.
        #expect(SolanaStakingTransactions.fits(message: Data(count: 1_167)))
        #expect(!SolanaStakingTransactions.fits(message: Data(count: 1_168)))
    }

    private func addresses(_ count: Int) throws -> [SolanaAddress] {
        try (0..<count).map { index in
            try SolanaAddress.createWithSeed(base: owner, seed: "stake:\(index)", owner: SolanaProgram.stake)
        }
    }

    private func messageSize(_ instructions: [SolanaInstruction]) throws -> Int {
        try SolanaMessage.compile(
            payer: owner,
            instructions: [
                ComputeBudgetProgram.setComputeUnitPrice(microLamports: .max),
                ComputeBudgetProgram.setComputeUnitLimit(1_400_000)
            ] + instructions,
            recentBlockhash: Data(count: 32)
        ).serialize().count
    }

    @Test(arguments: [false, true])
    func selectionLimitIsTheLastThatFitsWithComputeBudget(isWithdrawal: Bool) throws {
        let all = try addresses(40)
        let limit = try SolanaStakingTransactions.selectionLimit(
            owner: owner,
            addresses: all,
            isWithdrawal: isWithdrawal
        )

        func instructions(_ count: Int) -> [SolanaInstruction] {
            all.prefix(count).map {
                isWithdrawal
                    ? StakeProgram.withdraw(stake: $0, recipient: owner, withdrawer: owner, lamports: 1)
                    : StakeProgram.deactivate(stake: $0, staker: owner)
            }
        }

        #expect(limit > 10)
        #expect(limit < 40)
        #expect(try messageSize(instructions(limit)) + 65 <= 1_232)
        #expect(try messageSize(instructions(limit + 1)) + 65 > 1_232)
    }

    @Test func selectionLimitStopsAtTheAvailableAccounts() throws {
        let limit = try SolanaStakingTransactions.selectionLimit(
            owner: owner,
            addresses: try addresses(3),
            isWithdrawal: false
        )

        #expect(limit == 3)
    }
}
