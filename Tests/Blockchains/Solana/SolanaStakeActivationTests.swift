// Tests of the port of solana-program/stake's activation calculation (upstream's own vectors),
// each action's authority, the proof behind reward resolution, and epoch schedules.

import Foundation
import Testing
@testable import WalletKit

struct SolanaStakeActivationTests {
    // MARK: Activation

    private typealias Entry = SolanaStakeHistory.Entry

    /// `test_inflation_and_slashing_with_activating_and_deactivating_stake`'s history.
    private var upstreamHistory: SolanaStakeHistory {
        SolanaStakeHistory(entries: [
            0: Entry(activating: 700, deactivating: 0, effective: 1_000),
            1: Entry(activating: 450, deactivating: 0, effective: 1_250),
            2: Entry(activating: 138, deactivating: 0, effective: 1_562),
            3: Entry(activating: 0, deactivating: 0, effective: 1_700),
            4: Entry(activating: 0, deactivating: 700, effective: 1_700),
            5: Entry(activating: 0, deactivating: 275, effective: 1_275)
        ])
    }

    private func delegation(
        stake: UInt64 = 700,
        activation: UInt64 = 0,
        deactivation: UInt64 = .max
    ) -> SolanaStakeAccount.Delegation {
        .init(activationEpoch: activation, deactivationEpoch: deactivation, stake: stake, voter: "")
    }

    @Test func matchesUpstreamStatusTransition() {
        let stake = delegation(deactivation: 4)

        let expected: [SolanaStakeActivation] = [
            .init(activating: 700, effective: 0),
            .init(activating: 450, effective: 250),
            .init(activating: 138, effective: 562),
            .init(effective: 700),
            .init(deactivating: 700, effective: 700),
            .init(deactivating: 275, effective: 275),
            .init()
        ]

        for (epoch, status) in expected.enumerated() {
            #expect(stake.activation(at: UInt64(epoch), history: upstreamHistory, newRateEpoch: nil) == status)
        }
    }

    /// `test_stop_activating_after_deactivation`: other stakers activating during this one's
    /// cooldown don't restart its warmup.
    @Test func matchesUpstreamStopActivatingAfterDeactivation() {
        let stake = delegation(stake: 1_000, deactivation: 3)
        let base: UInt64 = 1_000
        let otherActivation: UInt64 = 100

        var entries: [UInt64: Entry] = [:]
        var effective = base
        var others: [UInt64] = [0]

        for epoch in UInt64(0)...4 {
            let activating: UInt64
            let deactivating: UInt64

            if epoch < 3 {
                activating = 1_000 + base - effective
                deactivating = 0
            } else {
                activating = otherActivation
                deactivating = effective - base - others.reduce(0, +)
            }

            entries[epoch] = Entry(activating: activating, deactivating: deactivating, effective: effective)

            let limited = effective * 2_500 / 10_000

            if epoch < 3 {
                effective += min(limited, activating)
                others.append(0)
            } else {
                effective -= min(limited, deactivating)
                effective += otherActivation
                others.append(otherActivation)
            }
        }

        let history = SolanaStakeHistory(entries: entries)

        for epoch in UInt64(0)...4 {
            let entry = entries[epoch] ?? Entry(activating: 0, deactivating: 0, effective: 0)
            let expectedStake = entry.effective - base - others[...Int(epoch)].reduce(0, +)

            #expect(stake.activation(at: epoch, history: history, newRateEpoch: nil) == .init(
                activating: epoch < 3 ? entry.activating : 0,
                deactivating: epoch < 3 ? 0 : entry.deactivating,
                effective: expectedStake
            ))
        }
    }

    @Test func noEntryAtTheActivationEpochMeansFullyEffective() {
        let empty = SolanaStakeHistory(entries: [:])
        #expect(delegation(activation: 5).activation(at: 9, history: empty, newRateEpoch: nil) == .init(effective: 700))
    }

    @Test func noEntryAtTheDeactivationEpochMeansFullyDeactivated() {
        let empty = SolanaStakeHistory(entries: [:])
        let stake = delegation(activation: 5, deactivation: 6)
        #expect(stake.activation(at: 9, history: empty, newRateEpoch: nil) == .init())
    }

    @Test func missingWarmupEntryKeepsThePartialResult() {
        let history = SolanaStakeHistory(entries: [0: Entry(activating: 700, deactivating: 0, effective: 1_000)])
        // Epoch 1 applies from entry 0; entry 1 is missing, so nothing more is assumed.
        let activation = delegation().activation(at: 5, history: history, newRateEpoch: nil)
        #expect(activation == .init(activating: 450, effective: 250))
    }

    @Test func missingCooldownEntryKeepsThePartialResultAndWithdrawHidden() {
        let history = SolanaStakeHistory(entries: [
            3: Entry(activating: 700, deactivating: 0, effective: 10_000),
            4: Entry(activating: 0, deactivating: 700, effective: 1_000)
        ])

        let stake = delegation(activation: 3, deactivation: 4)

        let activation = stake.activation(at: 9, history: history, newRateEpoch: nil)
        #expect(activation == .init(deactivating: 450, effective: 450))
        #expect(account(stake).status(at: 9, history: history, newRateEpoch: nil) == .deactivating)
    }

    @Test func sameEpochActivationAndDeactivationIsNoStakeAtAnyEpoch() {
        let stake = delegation(activation: 2, deactivation: 2)

        for epoch in UInt64(0)...5 {
            #expect(stake.activation(at: epoch, history: upstreamHistory, newRateEpoch: nil).effective == 0)
        }
    }

    @Test func bootstrapStakeIsImmediatelyEffective() {
        let activation = delegation(activation: .max).activation(at: 1, history: upstreamHistory, newRateEpoch: nil)
        #expect(activation == .init(effective: 700))
    }

    @Test func rateFollowsTheEpochBeingComputed() {
        let history = upstreamHistory

        // 9% from the start: 700 * 1000 * 900 / (700 * 10000).
        #expect(delegation().activation(at: 1, history: history, newRateEpoch: 0).effective == 90)
        // 25% into epoch 1, then 9% into epoch 2: 250 + 450 * 1250 * 900 / (450 * 10000).
        #expect(delegation().activation(at: 2, history: history, newRateEpoch: 2).effective == 362)
        // `nil` never switches.
        #expect(delegation().activation(at: 2, history: history, newRateEpoch: nil).effective == 562)
    }

    @Test func allowanceSaturatesRatherThanOverflowing() {
        let history = SolanaStakeHistory(entries: [
            0: Entry(activating: .max, deactivating: 0, effective: .max)
        ])
        let stake = delegation(stake: .max)

        #expect(stake.activation(at: 1, history: history, newRateEpoch: nil).effective > 0)
    }

    // MARK: Status

    private func account(_ delegation: SolanaStakeAccount.Delegation?) -> SolanaStakeAccount {
        SolanaStakeAccount(
            address: "x",
            delegation: delegation,
            lamports: 700,
            lockup: .init(custodian: "", epoch: 0, unixTimestamp: 0),
            rentExemptReserve: 0,
            staker: "me",
            withdrawer: "me"
        )
    }

    @Test func statusFollowsTheActivation() {
        let history = upstreamHistory

        #expect(account(nil).status(at: 1, history: history, newRateEpoch: nil) == .undelegated)
        #expect(account(delegation()).status(at: 1, history: history, newRateEpoch: nil) == .activating)
        #expect(account(delegation()).status(at: 3, history: history, newRateEpoch: nil) == .active)

        let deactivated = account(delegation(deactivation: 4))
        #expect(deactivated.status(at: 4, history: history, newRateEpoch: nil) == .deactivating)
        #expect(deactivated.status(at: 6, history: history, newRateEpoch: nil) == .inactive)

        #expect(account(delegation(activation: .max)).status(at: 1, history: history, newRateEpoch: nil) == .active)
    }

    @Test func actionsFollowTheirOwnAuthority() {
        let clock = SolanaClock(epoch: 6, epochStartTimestamp: 0, slot: 0, unixTimestamp: 100)

        func position(
            status: SolanaStakeStatus,
            staker: String = "me",
            withdrawer: String = "me",
            lockupTimestamp: Int64 = 0
        ) -> SolanaStakePosition {
            SolanaStakePosition(
                account: SolanaStakeAccount(
                    address: "x",
                    delegation: delegation(),
                    lamports: 1,
                    lockup: .init(custodian: "", epoch: 0, unixTimestamp: lockupTimestamp),
                    rentExemptReserve: 0,
                    staker: staker,
                    withdrawer: withdrawer
                ),
                activation: .init(),
                status: status
            )
        }

        #expect(position(status: .active).canUnstake(owner: "me"))
        #expect(!position(status: .active, staker: "other").canUnstake(owner: "me"))
        // Only the staker matters for unstaking; lockup doesn't block it.
        #expect(position(status: .active, withdrawer: "other").canUnstake(owner: "me"))
        #expect(position(status: .active, lockupTimestamp: 999).canUnstake(owner: "me"))
        #expect(!position(status: .inactive).canUnstake(owner: "me"))

        #expect(position(status: .inactive).canWithdraw(owner: "me", at: clock))
        #expect(position(status: .undelegated).canWithdraw(owner: "me", at: clock))
        #expect(position(status: .inactive, staker: "other").canWithdraw(owner: "me", at: clock))
        #expect(!position(status: .inactive, withdrawer: "other").canWithdraw(owner: "me", at: clock))
        #expect(!position(status: .inactive, lockupTimestamp: 999).canWithdraw(owner: "me", at: clock))
        #expect(!position(status: .deactivating).canWithdraw(owner: "me", at: clock))
    }

    // MARK: Reward proof

    @Test func aDeactivationBeforeTheRewardEpochProvesNothingWhileStakeCools() {
        // Deactivated in 4, still cooling in 5: a null for epoch 5 isn't proof of zero.
        let stake = delegation(deactivation: 4)
        #expect(!stake.provesNoEffectiveStake(in: 5, history: upstreamHistory, newRateEpoch: nil))
    }

    @Test func historyProvesZeroOnceFullyCooled() {
        let stake = delegation(deactivation: 4)
        #expect(stake.provesNoEffectiveStake(in: 6, history: upstreamHistory, newRateEpoch: nil))
    }

    @Test func aMissingEntryProvesNothing() {
        let empty = SolanaStakeHistory(entries: [:])
        let stake = delegation(activation: 1, deactivation: 2)
        #expect(!stake.provesNoEffectiveStake(in: 5, history: empty, newRateEpoch: nil))
    }

    @Test func aLaterActivationProvesNothing() {
        // It may have been redelegated after earning in that epoch.
        #expect(!delegation(activation: 5).provesNoEffectiveStake(in: 4, history: upstreamHistory, newRateEpoch: nil))
    }

    @Test func activationInTheRewardEpochProvesZero() {
        #expect(delegation(activation: 4).provesNoEffectiveStake(in: 4, history: upstreamHistory, newRateEpoch: nil))
    }

    @Test func anActiveDelegationProvesNothing() {
        // Looks active today, whether or not it existed then: a split child inherits this.
        #expect(!delegation().provesNoEffectiveStake(in: 3, history: upstreamHistory, newRateEpoch: nil))
    }

    // MARK: Epoch schedule

    @Test func normalEpochs() {
        let schedule = SolanaEpochSchedule(firstNormalEpoch: 0, firstNormalSlot: 0, slotsPerEpoch: 432_000)
        let position = schedule.epochAndIndex(of: 244_080_000)

        #expect(position.epoch == 565)
        #expect(position.index == 0)
        #expect(schedule.slotsRemaining(after: 432_000 + 2) == 431_998)
    }

    @Test func warmupEpochsDouble() {
        let schedule = SolanaEpochSchedule(firstNormalEpoch: 2, firstNormalSlot: 96, slotsPerEpoch: 128)

        #expect(schedule.epochAndIndex(of: 0).epoch == 0)
        #expect(schedule.epochAndIndex(of: 31).epoch == 0)
        #expect(schedule.epochAndIndex(of: 32).epoch == 1)
        #expect(schedule.epochAndIndex(of: 40).index == 8)
        #expect(schedule.epochAndIndex(of: 96).epoch == 2)
        #expect(schedule.slotsInEpoch(1) == 64)
        #expect(schedule.slotsInEpoch(5) == 128)
    }
}
