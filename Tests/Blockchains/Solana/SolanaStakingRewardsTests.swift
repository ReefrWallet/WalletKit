// Tests of building staking transactions, resolving rewards and listing validators against a fake node.

import Foundation
import Testing
@testable import WalletKit

private let owner = stakingOwner

@Suite(.timeLimit(.minutes(1)))
struct SolanaStakingPrepareTests {
    private func node(simulation: String) -> FakeSolanaNode {
        let node = makeStakingNode()
        let blockhash = Base58.encode(Data(repeating: 9, count: 32))

        node.on("getLatestBlockhash", result: #"""
        {"context":{"slot":5},"value":{"blockhash":"\#(blockhash)","lastValidBlockHeight":77}}
        """#)

        node.on("getRecentPrioritizationFees", result: "[]")
        node.on("getFeeForMessage", result: #"{"context":{"slot":5},"value":5000}"#)
        node.on("simulateTransaction", result: simulation)
        return node
    }

    private let account = "GEimxzEMpnvAALuhRXgPYk1LuKGJR8Zb1G7wKCwt44Kz"

    @Test func sizesTheLimitFromSimulationAndKeepsTheValidityData() async throws {
        let simulation = #"{"context":{"slot":5},"value":{"err":null,"logs":[],"unitsConsumed":10000}}"#
        let prepared = try await node(simulation: simulation)
            .client()
            .prepareStaking(.unstake(accounts: [account]), owner: owner)

        #expect(prepared.lastValidBlockHeight == 77)
        #expect(prepared.slotAtBuild == 5)
        #expect(prepared.recentBlockhash == Base58.encode(Data(repeating: 9, count: 32)))
        #expect(prepared.estimate.computeUnitLimit == 13_000)
    }

    @Test func aRejectedSimulationSaysWhy() async {
        let reason = "Program Stake11 failed: custom program error: 0x4"
        let failing = #"""
        {"context":{"slot":5},"value":{"err":{"InstructionError":[0,{"Custom":4}]},
         "logs":["Program log: x","\#(reason)"],"unitsConsumed":1}}
        """#

        await #expect(throws: SolanaStakingBuildError.simulationFailed(reason)) {
            try await node(simulation: failing).client().prepareStaking(.unstake(accounts: [account]), owner: owner)
        }
    }

    @Test func rewardPayoutIsItsOwnError() async {
        let failing = #"""
        {"context":{"slot":5},"value":{"err":{"InstructionError":[0,{"Custom":16}]},
         "logs":["Program Stake11 failed: custom program error: 0x10"],"unitsConsumed":1}}
        """#

        await #expect(throws: SolanaStakingBuildError.epochRewardsActive) {
            try await node(simulation: failing).client().prepareStaking(.unstake(accounts: [account]), owner: owner)
        }
    }

    @Test func tooManyAccountsNeverReachSimulation() async {
        let node = node(simulation: "null")

        // Distinct: duplicates share an account key and compile small.
        let distinct = (0..<40).compactMap {
            try? SolanaAddress.createWithSeed(base: owner, seed: "stake:\($0)", owner: SolanaProgram.stake).string
        }

        await #expect(throws: SolanaStakingBuildError.transactionTooLarge) {
            try await node.client().prepareStaking(.unstake(accounts: distinct), owner: owner)
        }

        #expect(node.count("simulateTransaction") == 0)
    }
}

@Suite(.timeLimit(.minutes(1)))
struct SolanaStakingRewardsTests {
    private func read(
        accounts: [SolanaStakeAccount],
        epoch: UInt64 = 7,
        history: [UInt64: SolanaStakeHistory.Entry] = [:]
    ) -> SolanaStakingRead {
        SolanaStakingRead(
            accounts: accounts,
            clock: SolanaClock(epoch: epoch, epochStartTimestamp: 0, slot: 0, unixTimestamp: 0),
            discovery: .complete,
            history: SolanaStakeHistory(entries: history),
            newRateEpoch: nil,
            schedule: SolanaEpochSchedule(firstNormalEpoch: 0, firstNormalSlot: 0, slotsPerEpoch: 100),
            slotDuration: nil
        )
    }

    private func account(_ address: String, delegation: SolanaStakeAccount.Delegation?) -> SolanaStakeAccount {
        SolanaStakeAccount(
            address: address,
            delegation: delegation,
            lamports: 10,
            lockup: .init(custodian: "", epoch: 0, unixTimestamp: 0),
            rentExemptReserve: 0,
            staker: owner.string,
            withdrawer: owner.string
        )
    }

    /// Node answering `getInflationReward` in address order, from `amounts`.
    private func node(_ amounts: [String: UInt64]) -> FakeSolanaNode {
        let node = FakeSolanaNode()

        node.on("getInflationReward") { params in
            let addresses = params.first as? [String] ?? []
            let values = addresses.map { address -> String in
                amounts[address].map { #"{"amount":\#($0),"effectiveSlot":1,"epoch":6,"postBalance":1}"# } ?? "null"
            }

            return "[\(values.joined(separator: ","))]"
        }

        return node
    }

    private let active = SolanaStakeAccount.Delegation(
        activationEpoch: 1,
        deactivationEpoch: .max,
        stake: 10,
        voter: "v"
    )

    @Test func nonNullResultsAreRewarded() async throws {
        let rewards = try await node(["a": 5, "b": 7]).client().stakingRewards(
            read: read(accounts: [account("a", delegation: active), account("b", delegation: active)]),
            retired: []
        )

        #expect(rewards?.epoch == 6)
        #expect(rewards?.lamports == 12)
        #expect(rewards?.unknownAddresses.isEmpty == true)
    }

    /// A split child inherits its parent's activation epoch, so it looks like it earned.
    @Test func splitChildCreatedAfterTheRewardedEpochStaysUnknown() async throws {
        let rewards = try await node(["parent": 9]).client().stakingRewards(
            read: read(accounts: [account("parent", delegation: active), account("child", delegation: active)]),
            retired: []
        )

        #expect(rewards?.lamports == 9)
        #expect(rewards?.unknownAddresses == ["child"])
    }

    @Test func fullyWithdrawnAccountsRewardStillCounts() async throws {
        let rewards = try await node(["gone": 4]).client().stakingRewards(
            read: read(accounts: []),
            retired: ["gone"]
        )

        #expect(rewards?.queriedAddresses == ["gone"])
        #expect(rewards?.lamports == 4)
    }

    @Test func retiredAddressWithNoResultIsUnknown() async throws {
        let rewards = try await node([:]).client().stakingRewards(read: read(accounts: []), retired: ["gone"])
        #expect(rewards?.unknownAddresses == ["gone"])
    }

    @Test func cooldownSpanningEpochsWithNullStaysUnknown() async throws {
        let cooling = SolanaStakeAccount.Delegation(activationEpoch: 0, deactivationEpoch: 4, stake: 700, voter: "v")

        let rewards = try await node([:]).client().stakingRewards(
            read: read(accounts: [account("a", delegation: cooling)], history: [
                0: .init(activating: 700, deactivating: 0, effective: 10_000),
                4: .init(activating: 0, deactivating: 700, effective: 800),
                5: .init(activating: 0, deactivating: 500, effective: 700),
                6: .init(activating: 0, deactivating: 325, effective: 600)
            ]),
            retired: []
        )

        #expect(rewards?.unknownAddresses == ["a"])
    }

    @Test func neverDelegatedIsProvenNotEarning() async throws {
        let rewards = try await node([:]).client().stakingRewards(
            read: read(accounts: [account("a", delegation: nil)]),
            retired: []
        )

        #expect(rewards?.unknownAddresses.isEmpty == true)
        #expect(rewards?.lamports == 0)
    }

    @Test func activationInTheRewardEpochIsProvenNotEarning() async throws {
        let fresh = SolanaStakeAccount.Delegation(activationEpoch: 6, deactivationEpoch: .max, stake: 10, voter: "v")

        let rewards = try await node([:]).client().stakingRewards(
            read: read(accounts: [account("a", delegation: fresh)]),
            retired: []
        )

        #expect(rewards?.unknownAddresses.isEmpty == true)
    }

    @Test func noHistoricalEntryLeavesItUnknown() async throws {
        let gone = SolanaStakeAccount.Delegation(activationEpoch: 1, deactivationEpoch: 2, stake: 10, voter: "v")

        let rewards = try await node([:]).client().stakingRewards(
            read: read(accounts: [account("a", delegation: gone)]),
            retired: []
        )

        #expect(rewards?.unknownAddresses == ["a"])
    }

    @Test func nothingToAskAbout() async throws {
        let rewards = try await node([:]).client().stakingRewards(read: read(accounts: []), retired: [])
        #expect(rewards == nil)
    }

    @Test func aFailedCallThrows() async {
        let node = FakeSolanaNode()

        let staked = read(accounts: [account("a", delegation: active)])

        await #expect(throws: BlockchainClientError.self) {
            try await node.client().stakingRewards(read: staked, retired: [])
        }
    }
}

// MARK: - Validators

@Suite(.timeLimit(.minutes(1)))
struct SolanaValidatorsTests {
    private let voteAccounts = """
    {"current":[
      {"activatedStake":10,"commission":5,"votePubkey":"low-stake"},
      {"activatedStake":99,"commission":5,"votePubkey":"high-stake"},
      {"activatedStake":99,"commission":1,"votePubkey":"cheap"}
    ],"delinquent":[{"activatedStake":1,"commission":0,"votePubkey":"down"}]}
    """

    @Test func fallsBackToTheNodeSortedByCommissionThenStake() async throws {
        let node = FakeSolanaNode()
        node.on("getVoteAccounts", result: voteAccounts)

        let validators = try await node.client().validators()

        #expect(validators.map(\.voteAddress) == ["down", "cheap", "high-stake", "low-stake"])
        #expect(validators.first?.isDelinquent == true)
        #expect(validators.allSatisfy { $0.name == nil && $0.apy == nil })
    }

    @Test func indexRanksByScoreAndKeepsFields() throws {
        let json = #"""
        [{"vote_identity":"b","name":"","image":null,"commission":3,"total_apy":6.8449,
          "wiz_score":10,"delinquent":false},
         {"vote_identity":"a","name":"Alpha","image":"https://x.test/a.png","commission":0,"total_apy":7,
          "wiz_score":90,"delinquent":true}]
        """#

        let decoded = try JSONDecoder().decode([SolanaStakewiz.Validator].self, from: Data(json.utf8))
        let first = decoded[0].validator
        let second = decoded[1].validator

        #expect(first.name == nil)
        #expect(first.apy == Decimal(string: "6.84"))
        #expect(second.name == "Alpha")
        #expect(second.isDelinquent)
        #expect(second.imageURL?.host == "x.test")
    }
}
