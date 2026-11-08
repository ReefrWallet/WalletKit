// Coverage for the Sui staking read side. The dynamic-field id vectors are
// real mainnet values (pool exchange-rate table entries observed through
// gRPC); the reward cases are hand-computed from `0x3::staking_pool`'s
// integer arithmetic, so they pin rounding, flooring, capping and the 1:1
// fallback rather than reproduce the implementation.

import Foundation
import SwiftProtobuf
import Testing
@testable import WalletKit
import WalletKitGRPC

private extension Data {
    var hex: String { map { String(format: "%02x", $0) }.joined() }
}

struct SuiDynamicFieldIdTests {
    private static let table = "fc84a891514f2eb7f098457bf6451cb36886332116caaa52fce82249c9cabe48"

    @Test(arguments: [
        (1081, "006a3606f9c15f329745ceacc053233dcbebb9050be6407e36a3a1a02c266f3f"),
        (624, "00a2012b176c4927fc04e26c792fd5990cb252014471fe7aa02f72bc811ec6f9")
    ])
    func matchesMainnetFieldIds(epoch: UInt64, expected: String) throws {
        let table = try Data(hexString: Self.table)
        #expect(SuiDynamicFieldId.epochKey(table: table, epoch: epoch).hex == expected)
    }
}

struct SuiStakingMathTests {
    private let rate = SuiPoolExchangeRate(suiAmount: 110, poolTokenAmount: 100)
    private let flat = SuiPoolExchangeRate(suiAmount: 100, poolTokenAmount: 100)

    @Test
    func rewardIsTheGrowthOfPoolTokens() {
        let reward = SuiStakingMath.estimatedReward(
            principal: 1_000_000_000, activationRate: flat, currentRate: rate, rewardsPool: .max
        )
        #expect(reward == 100_000_000)
    }

    @Test
    func rewardIsCappedByTheRewardsPool() {
        let reward = SuiStakingMath.estimatedReward(
            principal: 1_000_000_000, activationRate: flat, currentRate: rate, rewardsPool: 50_000_000
        )
        #expect(reward == 50_000_000)
    }

    @Test
    func rewardIsFlooredAtZero() {
        let reward = SuiStakingMath.estimatedReward(
            principal: 1_000_000_000,
            activationRate: flat,
            currentRate: SuiPoolExchangeRate(suiAmount: 90, poolTokenAmount: 100),
            rewardsPool: .max
        )
        #expect(reward == 0)
    }

    @Test
    func conversionsRoundDownLikeMove() {
        // 7 MIST at 3 SUI : 2 tokens is 4 tokens (14/3), worth 6 MIST (12/2): below principal.
        let rate = SuiPoolExchangeRate(suiAmount: 3, poolTokenAmount: 2)
        #expect(rate.tokenAmount(forSui: 7) == 4)
        #expect(rate.suiAmount(forTokens: 4) == 6)

        let reward = SuiStakingMath.estimatedReward(
            principal: 7, activationRate: rate, currentRate: rate, rewardsPool: 9
        )
        #expect(reward == 0)
    }

    @Test(arguments: [
        SuiPoolExchangeRate(suiAmount: 0, poolTokenAmount: 100),
        SuiPoolExchangeRate(suiAmount: 100, poolTokenAmount: 0),
        SuiPoolExchangeRate.initial
    ])
    func zeroEitherFieldMeansOneToOne(rate: SuiPoolExchangeRate) {
        #expect(rate.tokenAmount(forSui: 1234) == 1234)
        #expect(rate.suiAmount(forTokens: 1234) == 1234)
    }

    @Test
    func initialRateStillYieldsAnEstimateRatherThanUnavailable() {
        let reward = SuiStakingMath.estimatedReward(
            principal: 1000, activationRate: .initial, currentRate: rate, rewardsPool: .max
        )
        #expect(reward == 100)
    }

    /// Real mainnet stakes (epoch 1305). Each expected reward is what a simulated `request_withdraw_stake`
    /// actually paid beyond principal: balance change plus the transaction's net gas cost, minus principal.
    struct MainnetWithdrawal: Sendable, CustomTestStringConvertible {
        let principal: UInt64
        let activationRate: SuiPoolExchangeRate
        let reward: UInt64

        var testDescription: String { "principal \(principal)" }
    }

    @Test(arguments: [
        MainnetWithdrawal(
            principal: 33_719_739_949,
            activationRate: SuiPoolExchangeRate(
                suiAmount: 10_061_741_038_003_610, poolTokenAmount: 9_190_677_733_060_104
            ),
            reward: 33_864_033
        ),
        MainnetWithdrawal(
            principal: 31_875_163_419,
            activationRate: SuiPoolExchangeRate(
                suiAmount: 10_051_963_435_384_719, poolTokenAmount: 9_189_856_700_719_081
            ),
            reward: 60_194_713
        ),
        MainnetWithdrawal(
            principal: 28_760_877_583,
            activationRate: SuiPoolExchangeRate(
                suiAmount: 9_389_847_625_908_129, poolTokenAmount: 8_574_512_714_941_925
            ),
            reward: 20_698_286
        )
    ])
    func matchesSimulatedMainnetWithdrawals(case withdrawal: MainnetWithdrawal) {
        let current = SuiPoolExchangeRate(suiAmount: 9_394_869_976_481_460, poolTokenAmount: 8_572_929_303_038_302)
        let reward = SuiStakingMath.estimatedReward(
            principal: withdrawal.principal,
            activationRate: withdrawal.activationRate,
            currentRate: current,
            rewardsPool: .max
        )
        #expect(reward == withdrawal.reward)
    }

    @Test
    func unreadableCurrentRateDoesNotFallBackToAnOlderOne() {
        let older = SuiPoolExchangeRate(suiAmount: 105, poolTokenAmount: 100)
        let skipped = SuiStakingMath.rate(
            epoch: 12, activationEpoch: 5, deactivationEpoch: nil, entries: [11: older], lookback: 7
        )
        #expect(skipped == older, "an explicitly absent epoch is skipped, as Move does")

        let unreadable = SuiStakingMath.rate(
            epoch: 12, activationEpoch: 5, deactivationEpoch: nil, entries: [11: older], unreadable: [12], lookback: 7
        )
        #expect(unreadable == nil, "an unreadable epoch may hold the real entry")

        let belowTheEntry = SuiStakingMath.rate(
            epoch: 12, activationEpoch: 5, deactivationEpoch: nil, entries: [12: rate], unreadable: [11], lookback: 7
        )
        #expect(belowTheEntry == rate, "unreadable epochs below a found entry do not matter")
    }

    @Test
    func overflowIsNilNotATrap() {
        let huge = SuiPoolExchangeRate(suiAmount: .max, poolTokenAmount: 1)
        #expect(huge.suiAmount(forTokens: 2) == nil)
    }

    @Test
    func lookupWalksBackToTheLatestEarlierEntry() {
        let result = SuiStakingMath.lookup(
            epoch: 12, activationEpoch: 5, deactivationEpoch: nil, entries: [10: rate], fetched: 5...12
        )
        #expect(result == .rate(rate))
    }

    @Test
    func lookupBeforeActivationIsInitial() {
        let result = SuiStakingMath.lookup(
            epoch: 4, activationEpoch: 5, deactivationEpoch: nil, entries: [:], fetched: 0...4
        )
        #expect(result == .initial)

        let preactive = SuiStakingMath.lookup(
            epoch: 4, activationEpoch: nil, deactivationEpoch: nil, entries: [:], fetched: 0...4
        )
        #expect(preactive == .initial)
    }

    @Test
    func lookupClampsToTheDeactivationEpoch() {
        let older = SuiPoolExchangeRate(suiAmount: 105, poolTokenAmount: 100)
        let result = SuiStakingMath.lookup(
            epoch: 12, activationEpoch: 5, deactivationEpoch: 8, entries: [8: older, 10: rate], fetched: 5...8
        )
        #expect(result == .rate(older))
    }

    @Test
    func lookupOutsideTheFetchedWindowIsUnavailableNotInitial() {
        let result = SuiStakingMath.lookup(
            epoch: 12, activationEpoch: 5, deactivationEpoch: nil, entries: [:], fetched: 9...12
        )
        #expect(result == .unavailable)

        let missing = SuiStakingMath.rate(
            epoch: 12, activationEpoch: 5, deactivationEpoch: nil, entries: [:], lookback: 3
        )
        #expect(missing == nil)
    }

    @Test
    func fetchWindowIsBoundedByLookbackAndActivation() {
        func window(_ epoch: UInt64, _ activation: UInt64?, _ deactivation: UInt64? = nil) -> ClosedRange<UInt64>? {
            SuiStakingMath.fetchWindow(
                epoch: epoch, activationEpoch: activation, deactivationEpoch: deactivation, lookback: 7
            )
        }

        #expect(window(100, 0) == 93...100)
        #expect(window(100, 98) == 98...100)
        #expect(window(100, 0, 50) == 43...50)
        #expect(window(100, 101) == nil)
        #expect(window(100, nil) == nil)
    }

    @Test
    func pendingStakeEarnsNothing() throws {
        // Activates next epoch (13) while the pool's latest entry is epoch 12: both rates resolve to epoch 12's.
        let entries: [UInt64: SuiPoolExchangeRate] = [12: rate]
        func resolved(at epoch: UInt64) -> SuiPoolExchangeRate? {
            SuiStakingMath.rate(
                epoch: epoch, activationEpoch: 0, deactivationEpoch: nil, entries: entries, lookback: 7
            )
        }

        let reward = SuiStakingMath.estimatedReward(
            principal: 5_000_000_000,
            activationRate: try #require(resolved(at: 13)),
            currentRate: try #require(resolved(at: 12)),
            rewardsPool: .max
        )
        #expect(reward == 0)
    }
}

struct SuiRateObjectOutcomeTests {
    private func rateObject(count: Int) -> Sui_Rpc_V2_GetObjectResult {
        let bytes = Data(repeating: 0, count: 40) + BCS.u64(110) + BCS.u64(100) + Data(repeating: 0, count: count - 56)
        return Sui_Rpc_V2_GetObjectResult.with {
            $0.object = Sui_Rpc_V2_Object.with { $0.contents = Sui_Rpc_V2_Bcs.with { $0.value = bytes } }
        }
    }

    private func failure(code: Int32) -> Sui_Rpc_V2_GetObjectResult {
        Sui_Rpc_V2_GetObjectResult.with { $0.error = Google_Rpc_Status.with { $0.code = code } }
    }

    @Test
    func onlyAnExplicitNotFoundMeansNoEntry() {
        #expect(SuiGRPCClient.rateOutcome(failure(code: 5)) == .notFound)
        #expect(SuiGRPCClient.rateOutcome(failure(code: 14)) == .unreadable)
        #expect(SuiGRPCClient.rateOutcome(failure(code: 2)) == .unreadable)
        #expect(SuiGRPCClient.rateOutcome(Sui_Rpc_V2_GetObjectResult()) == .unreadable)
    }

    @Test
    func wellFormedContentsYieldARate() {
        let expected = SuiPoolExchangeRate(suiAmount: 110, poolTokenAmount: 100)
        #expect(SuiGRPCClient.rateOutcome(rateObject(count: 56)) == .rate(expected))
    }

    @Test
    func malformedContentsAreUnreadableNotAbsent() {
        #expect(SuiGRPCClient.rateOutcome(rateObject(count: 60)) == .unreadable)
        let truncated = Sui_Rpc_V2_GetObjectResult.with {
            $0.object = Sui_Rpc_V2_Object.with { $0.contents = Sui_Rpc_V2_Bcs.with { $0.value = Data(count: 55) } }
        }
        #expect(SuiGRPCClient.rateOutcome(truncated) == .unreadable)
    }
}

struct SuiRateBatchMappingTests {
    private func rate(sui: UInt64) -> Sui_Rpc_V2_GetObjectResult {
        let bytes = Data(repeating: 0, count: 40) + BCS.u64(sui) + BCS.u64(100)
        return Sui_Rpc_V2_GetObjectResult.with {
            $0.object = Sui_Rpc_V2_Object.with { $0.contents = Sui_Rpc_V2_Bcs.with { $0.value = bytes } }
        }
    }

    private var notFound: Sui_Rpc_V2_GetObjectResult {
        Sui_Rpc_V2_GetObjectResult.with { $0.error = Google_Rpc_Status.with { $0.code = 5 } }
    }

    @Test
    func mapsOneResultPerEpochByPosition() {
        let results = [rate(sui: 110), notFound, rate(sui: 112)]
        let entries = SuiGRPCClient.rateEntries(epochs: [10, 11, 12], results: results)
        #expect(entries.rates[10]?.suiAmount == 110)
        #expect(entries.rates[11] == nil)
        #expect(entries.rates[12]?.suiAmount == 112)
        #expect(entries.unreadable.isEmpty)
    }

    @Test(arguments: [0, 1, 2, 4])
    func aMismatchedResultCountIsNeverMappedByPosition(count: Int) {
        // Whatever is missing, a later rate must not land on an earlier epoch.
        let results = Array([rate(sui: 110), rate(sui: 111), rate(sui: 112), rate(sui: 113)].prefix(count))
        let entries = SuiGRPCClient.rateEntries(epochs: [10, 11, 12], results: results)
        #expect(entries.rates.isEmpty)
        #expect(entries.unreadable == [10, 11, 12])
    }
}

struct SuiStakeStatusTests {
    @Test
    func aRetiredPoolIsNeverEarning() {
        #expect(SuiStakeStatus.status(activationEpoch: 5, epoch: 10, poolState: .inactive) == .retired)
        #expect(SuiStakeStatus.status(activationEpoch: 11, epoch: 10, poolState: .inactive) == .retired)
    }

    @Test
    func anUnknownPoolIsJudgedByTheEpochAlone() {
        #expect(SuiStakeStatus.status(activationEpoch: 5, epoch: 10, poolState: .unknown) == .earning)
        #expect(SuiStakeStatus.status(activationEpoch: 11, epoch: 10, poolState: .unknown) == .pending)
    }

    @Test
    func anActivePoolEarnsOnceActivated() {
        #expect(SuiStakeStatus.status(activationEpoch: 10, epoch: 10, poolState: .active) == .earning)
        #expect(SuiStakeStatus.status(activationEpoch: 11, epoch: 10, poolState: .active) == .pending)
    }
}

struct SuiStakedSuiDecodingTests {
    private func contents(pool: UInt8, epoch: UInt64, principal: UInt64) -> Data {
        Data(repeating: 0x01, count: 32) + Data(repeating: pool, count: 32) + BCS.u64(epoch) + BCS.u64(principal)
    }

    private func object(contents: Data) -> Sui_Rpc_V2_Object {
        Sui_Rpc_V2_Object.with {
            $0.objectID = "0x" + String(repeating: "01", count: 32)
            $0.version = 9
            $0.digest = "CxeKLJRofna6h2GqCsjdVwc2D7EdDFX8uDy9KGw3Ey68"
            $0.contents = Sui_Rpc_V2_Bcs.with { $0.value = contents }
        }
    }

    @Test
    func decodesPoolActivationEpochAndPrincipal() throws {
        let bytes = contents(pool: 0x02, epoch: 7, principal: 5_000_000_000)
        let stake = try SuiGRPCClient.stakedSui(from: object(contents: bytes))
        #expect(stake.poolId == "0x" + String(repeating: "02", count: 32))
        #expect(stake.activationEpoch == 7)
        #expect(stake.principal == 5_000_000_000)
        #expect(stake.version == 9)
        #expect(try stake.reference().digest == Data(repeating: 0xB1, count: 32))
    }

    @Test
    func rejectsUnexpectedLayouts() {
        #expect(throws: BlockchainClientError.self) {
            try SuiGRPCClient.stakedSui(from: object(contents: Data(repeating: 0, count: 79)))
        }
    }
}

struct SuiInactivePoolParsingTests {
    private let tableId = "0x6e4cf881b1acbbfd01ecec639108cde7ffc38967357b1e5dbf47a97aaf53bbf8"
    private let poolId = "0x4e22f6c2af318ea142ddf47912b06b03da5246806a558993e0f21f7d2937a5d0"

    private func text(_ string: String) -> Google_Protobuf_Value {
        Google_Protobuf_Value.with { $0.stringValue = string }
    }

    private func object(_ fields: [String: Google_Protobuf_Value]) -> Google_Protobuf_Value {
        Google_Protobuf_Value.with { $0.structValue = Google_Protobuf_Struct.with { $0.fields = fields } }
    }

    private func parse(deactivation: Google_Protobuf_Value) -> SuiInactivePool? {
        let pool = object([
            "activation_epoch": text("0"),
            "deactivation_epoch": deactivation,
            "exchange_rates": object(["id": text(tableId), "size": text("844")]),
            "id": text(poolId),
            "rewards_pool": text("260293692302"),
            "sui_balance": text("5594683260736")
        ])
        let metadata = object(["name": text("Old Validator"), "sui_address": text("0x4e22")])
        let field = object(["value": object(["metadata": metadata, "staking_pool": pool])])
        return SuiGRPCClient.inactivePool(from: field)
    }

    @Test
    func readsAMainnetShapedPool() throws {
        let entry = try #require(parse(deactivation: text("846")))
        #expect(entry.pool.activationEpoch == 0)
        #expect(entry.pool.deactivationEpoch == 846)
        #expect(entry.pool.rewardsPool == 260_293_692_302)
        #expect(entry.validatorName == "Old Validator")
        #expect(entry.pool.exchangeRatesTableId == tableId)
    }

    @Test
    func nullOptionIsNil() throws {
        let null = Google_Protobuf_Value.with { $0.nullValue = .nullValue }
        #expect(try #require(parse(deactivation: null)).pool.deactivationEpoch == nil)
    }
}

struct SuiStakingReadTests {
    private func position(principal: UInt64, reward: UInt64?) -> SuiStakePosition {
        SuiStakePosition(
            stake: SuiStakedSui(
                objectId: "0x1", version: 1, digest: "d", poolId: "0x2", activationEpoch: 1, principal: principal
            ),
            status: .earning,
            validatorAddress: nil,
            validatorName: nil,
            poolState: .active,
            estimatedReward: reward
        )
    }

    @Test
    func totalsAddUpOnlyWhenEveryRewardIsKnown() {
        let known = SuiStakingRead(
            epoch: 5, positions: [position(principal: 3, reward: 1), position(principal: 4, reward: 2)], validators: []
        )
        #expect(known.totalPrincipal == 7)
        #expect(known.totalEstimatedRewards == 3)

        let unknown = [position(principal: 3, reward: 1), position(principal: 4, reward: nil)]
        let partial = SuiStakingRead(epoch: 5, positions: unknown, validators: [])
        #expect(partial.totalEstimatedRewards == nil)
    }
}
