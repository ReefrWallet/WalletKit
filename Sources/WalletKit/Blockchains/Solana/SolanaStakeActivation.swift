//
//  SolanaStakeActivation.swift
//  WalletKit
//
//  Created by Andrey Yurkevich on 06/11/2026.
//  Copyright © 2026 Reefr Wallet. All rights reserved.
//

import Foundation

// MARK: - Activation

/// How much of a delegation is effective, warming up and cooling down in one epoch.
public struct SolanaStakeActivation: Codable, Equatable, Sendable {
    public let activating: UInt64
    public let deactivating: UInt64
    public let effective: UInt64

    public init(activating: UInt64 = 0, deactivating: UInt64 = 0, effective: UInt64 = 0) {
        self.activating = activating
        self.deactivating = deactivating
        self.effective = effective
    }
}

/// A stake account's phase, derived from its ``SolanaStakeActivation``.
public enum SolanaStakeStatus: String, Codable, Sendable {
    case activating
    case active
    case deactivating
    case inactive
    case undelegated
}

/// A port of `solana-program/stake` at `cf8925b7cb22403d2e31ad2042deee90b5f3b797`:
/// `stake_activating_and_deactivating_v2`, `stake_and_activating_v2` and
/// `warmup_cooldown_allowance.rs`. Keep its branches exact; each `usedMissingEntry` marks where
/// the reference assumes an outcome rather than computing it from a history entry.
public extension SolanaStakeAccount.Delegation {
    private struct Warmup {
        var activating: UInt64 = 0
        var effective: UInt64 = 0
        var usedMissingEntry = false
    }

    /// The activation at `target`.
    ///
    /// - Parameters:
    ///   - target: The epoch to evaluate.
    ///   - history: The cluster's stake history.
    ///   - newRateEpoch: The epoch the 9% rate started; `nil` keeps 25%.
    func activation(
        at target: UInt64,
        history: SolanaStakeHistory,
        newRateEpoch: UInt64?
    ) -> SolanaStakeActivation {
        evaluate(at: target, history: history, newRateEpoch: newRateEpoch).activation
    }

    /// Whether history proves no stake was effective in `epoch`: this delegation already held
    /// then, and the calculation used real entries only. A deactivation epoch before `epoch`
    /// isn't enough, since cooldown can span epochs; a later activation isn't either, since
    /// the account may have been redelegated.
    func provesNoEffectiveStake(
        in epoch: UInt64,
        history: SolanaStakeHistory,
        newRateEpoch: UInt64?
    ) -> Bool {
        guard !isBootstrap, activationEpoch <= epoch else {
            return false
        }

        let result = evaluate(at: epoch, history: history, newRateEpoch: newRateEpoch)
        return !result.usedMissingEntry && result.activation.effective == 0
    }

    private var isBootstrap: Bool {
        activationEpoch == .max
    }

    private func evaluate(
        at target: UInt64,
        history: SolanaStakeHistory,
        newRateEpoch: UInt64?
    ) -> (activation: SolanaStakeActivation, usedMissingEntry: Bool) {
        let warmup = effectiveAndActivating(at: target, history: history, newRateEpoch: newRateEpoch)
        let effective = warmup.effective

        if target < deactivationEpoch {
            return (SolanaStakeActivation(activating: warmup.activating, effective: effective), warmup.usedMissingEntry)
        }

        if target == deactivationEpoch {
            return (SolanaStakeActivation(deactivating: effective, effective: effective), warmup.usedMissingEntry)
        }

        guard var previous = history.entry(deactivationEpoch) else {
            return (SolanaStakeActivation(), true)
        }

        var previousEpoch = deactivationEpoch
        var remaining = effective
        var usedMissingEntry = warmup.usedMissingEntry

        while true {
            let epoch = previousEpoch + 1

            guard previous.deactivating != 0 else {
                break
            }

            let allowance = Self.allowance(
                epoch: epoch,
                account: remaining,
                cluster: previous.deactivating,
                clusterEffective: previous.effective,
                newRateEpoch: newRateEpoch
            )

            remaining -= min(remaining, max(allowance, 1))

            if remaining == 0 || epoch >= target {
                break
            }

            guard let next = history.entry(epoch) else {
                usedMissingEntry = true
                break
            }

            previousEpoch = epoch
            previous = next
        }

        return (SolanaStakeActivation(deactivating: remaining, effective: remaining), usedMissingEntry)
    }

    private func effectiveAndActivating(
        at target: UInt64,
        history: SolanaStakeHistory,
        newRateEpoch: UInt64?
    ) -> Warmup {
        if isBootstrap {
            return Warmup(effective: stake)
        }

        if activationEpoch == deactivationEpoch {
            return Warmup()
        }

        if target == activationEpoch {
            return Warmup(activating: stake)
        }

        if target < activationEpoch {
            return Warmup()
        }

        guard var previous = history.entry(activationEpoch) else {
            return Warmup(effective: stake, usedMissingEntry: true)
        }

        var previousEpoch = activationEpoch
        var activated: UInt64 = 0
        var usedMissingEntry = false

        while true {
            let epoch = previousEpoch + 1

            guard previous.activating != 0 else {
                break
            }

            let allowance = Self.allowance(
                epoch: epoch,
                account: stake - activated,
                cluster: previous.activating,
                clusterEffective: previous.effective,
                newRateEpoch: newRateEpoch
            )

            activated += max(allowance, 1)

            if activated >= stake {
                activated = stake
                break
            }

            if epoch >= target || epoch >= deactivationEpoch {
                break
            }

            guard let next = history.entry(epoch) else {
                usedMissingEntry = true
                break
            }

            previousEpoch = epoch
            previous = next
        }

        return Warmup(activating: stake - activated, effective: activated, usedMissingEntry: usedMissingEntry)
    }

    /// `min(account, account * clusterEffective * rate / (cluster * 10_000))` in saturating 128-bit math.
    private static func allowance(
        epoch: UInt64,
        account: UInt64,
        cluster: UInt64,
        clusterEffective: UInt64,
        newRateEpoch: UInt64?
    ) -> UInt64 {
        guard account != 0, cluster != 0, clusterEffective != 0 else {
            return 0
        }

        let rate: UInt64 = newRateEpoch.map { epoch >= $0 } == true ? 900 : 2_500

        let product = UInt128(account).multipliedReportingOverflow(by: UInt128(clusterEffective))
        let saturated = product.overflow ? UInt128.max : product.partialValue
        let scaled = saturated.multipliedReportingOverflow(by: UInt128(rate))
        let numerator = scaled.overflow ? UInt128.max : scaled.partialValue
        let denominator = UInt128(cluster) * 10_000

        return UInt64(min(numerator / denominator, UInt128(account)))
    }
}

public extension SolanaStakeAccount {
    /// The phase at `epoch`. Withdraw is offered only for `inactive` and `undelegated`.
    func status(at epoch: UInt64, history: SolanaStakeHistory, newRateEpoch: UInt64?) -> SolanaStakeStatus {
        guard let delegation else {
            return .undelegated
        }

        let activation = delegation.activation(at: epoch, history: history, newRateEpoch: newRateEpoch)

        guard delegation.deactivationEpoch != .max else {
            return activation.activating > 0 || activation.effective == 0 ? .activating : .active
        }

        if activation.deactivating > 0 || activation.effective > 0 || activation.activating > 0 {
            return .deactivating
        }

        return .inactive
    }
}
