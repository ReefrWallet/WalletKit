// Tests of reading stake accounts from a node: snapshot rules and the discovery fallback.

import Foundation
import Testing
@testable import WalletKit

private let otherWallet = stakingOtherWallet
private let owner = stakingOwner
private let voter = stakingVoter

@Suite(.timeLimit(.minutes(1)))
struct SolanaStakingReadTests {
    @Test func completeWhenBothQueriesAnswer() async throws {
        let node = makeStakingNode(programAccounts: [(stakeAddress, stakeData())])

        let read = try await node.client().stakingRead(owner: owner, known: [])

        #expect(read.discovery == .complete)
        #expect(read.accounts.map(\.address) == [stakeAddress])
        #expect(read.clock.epoch == 100)
        #expect(read.slotDuration == 0.2)
        #expect(node.count("getProgramAccounts") == 2)
    }

    @Test func historyNotEndingAtThePreviousEpochFailsTheRead() async {
        // A lagging node: otherwise a stake deactivated in 99 would read as fully deactivated.
        let node = makeStakingNode(epoch: 100, newestHistory: 98)

        await #expect(throws: BlockchainClientError.self) {
            try await node.client().stakingRead(owner: owner, known: [])
        }
    }

    @Test func missingHistoryAccountFailsTheRead() async {
        let node = makeStakingNode()
        let clock = accountJSON(clockData(), owner: "x")
        node.on("getMultipleAccounts", result: #"{"context":{"slot":1},"value":[\#(clock),null]}"#)

        await #expect(throws: BlockchainClientError.self) {
            try await node.client().stakingRead(owner: owner, known: [])
        }
    }

    @Test func refusedSnapshotFailsTheRead() async {
        let node = makeStakingNode()
        node.on("getMultipleAccounts") { _ in nil }

        await #expect(throws: BlockchainClientError.self) {
            try await node.client().stakingRead(owner: owner, known: [])
        }
    }

    @Test func emptyHistoryIsFineInTheFirstEpoch() async throws {
        let read = try await makeStakingNode(epoch: 0, newestHistory: nil).client().stakingRead(owner: owner, known: [])
        #expect(read.clock.epoch == 0)
    }

    @Test func newRateEpochComesFromTheFeatureAccount() async throws {
        let node = makeStakingNode()
        let feature = Data([1]) + stakingUInt64(244_080_000)
        let account = accountJSON(feature, owner: "Feature111111111111111111111111111111111111")
        node.on("getAccountInfo", result: #"{"context":{"slot":1},"value":\#(account)}"#)

        let read = try await node.client().stakingRead(owner: owner, known: [])
        #expect(read.newRateEpoch == 565)
    }

    @Test func inactiveFeatureKeepsTheOldRate() async throws {
        let read = try await makeStakingNode().client().stakingRead(owner: owner, known: [])
        #expect(read.newRateEpoch == nil)
    }

    // MARK: Degraded discovery

    /// Fails `getProgramAccounts`, and answers `found` for addresses other than the sysvars.
    private func degradedNode(found: [String: String]) -> FakeSolanaNode {
        let node = makeStakingNode()
        node.on("getProgramAccounts") { _ in nil }

        let snapshot = snapshotJSON()

        node.on("getMultipleAccounts") { params in
            let addresses = params.first as? [String] ?? []

            if addresses.first == SolanaProgram.sysvarClock.string {
                return snapshot
            }

            let values = addresses.map { found[$0] ?? "null" }
            return #"{"context":{"slot":1},"value":[\#(values.joined(separator: ","))]}"#
        }

        return node
    }

    @Test func degradedKeepsKnownAddressesItCanRefresh() async throws {
        let node = degradedNode(found: [stakeAddress: accountJSON(stakeData(), owner: SolanaProgram.stake.string)])

        let read = try await node.client().stakingRead(owner: owner, known: [stakeAddress])

        #expect(read.discovery == .degraded)
        #expect(read.accounts.map(\.address) == [stakeAddress])
    }

    @Test func degradedDropsAKnownAddressOnlyWhenProvenClosed() async throws {
        let read = try await degradedNode(found: [:]).client().stakingRead(owner: owner, known: [stakeAddress])

        #expect(read.discovery == .degraded)
        #expect(read.accounts.isEmpty)
    }

    @Test func degradedDropsAnAccountNoLongerUnderThisAuthority() async throws {
        let foreign = SolanaStakingTests.stakeAccountData(staker: otherWallet, withdrawer: otherWallet, voter: voter)
        let node = degradedNode(found: [stakeAddress: accountJSON(foreign, owner: SolanaProgram.stake.string)])

        let read = try await node.client().stakingRead(owner: owner, known: [stakeAddress])
        #expect(read.accounts.isEmpty)
    }

    @Test func degradedFindsAppSeeds() async throws {
        let seeded = try SolanaAddress.createWithSeed(base: owner, seed: "stake:3", owner: SolanaProgram.stake).string
        let node = degradedNode(found: [seeded: accountJSON(stakeData(), owner: SolanaProgram.stake.string)])

        let read = try await node.client().stakingRead(owner: owner, known: [])
        #expect(read.accounts.map(\.address) == [seeded])
    }

    @Test func fallbackFailingFailsTheRead() async {
        let node = degradedNode(found: [:])
        let snapshot = snapshotJSON()

        node.on("getMultipleAccounts") { params in
            (params.first as? [String])?.first == SolanaProgram.sysvarClock.string ? snapshot : nil
        }

        await #expect(throws: BlockchainClientError.self) {
            try await node.client().stakingRead(owner: owner, known: [stakeAddress])
        }
    }

    @Test func nextSeedSkipsTakenAddresses() async throws {
        let taken = try SolanaAddress.createWithSeed(base: owner, seed: "stake:0", owner: SolanaProgram.stake).string
        let node = degradedNode(found: [taken: accountJSON(stakeData(), owner: SolanaProgram.stake.string)])

        let next = try await node.client().nextStakeSeed(owner: owner)
        #expect(next.seed == "stake:1")
    }

    @Test func nextSeedPagesPastAFullPage() async throws {
        var found: [String: String] = [:]

        for index in 0..<32 {
            let address = try SolanaAddress.createWithSeed(
                base: owner,
                seed: "stake:\(index)",
                owner: SolanaProgram.stake
            )

            found[address.string] = accountJSON(stakeData(), owner: SolanaProgram.stake.string)
        }

        let next = try await degradedNode(found: found).client().nextStakeSeed(owner: owner)
        #expect(next.seed == "stake:32")
    }
}
