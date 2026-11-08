//
//  SuiStaking.swift
//  WalletKit
//
//  Created by Andrey Yurkevich on 08/11/2026.
//  Copyright © 2026 Reefr Wallet. All rights reserved.
//
//  Read-side model and reward maths for native Sui staking. Rewards mirror
//  `0x3::staking_pool` (`get_token_amount`, `get_sui_amount`,
//  `pool_token_exchange_rate_at_epoch`, `withdraw_rewards`).

import BigInt
import Foundation

/// A staking pool's `PoolTokenExchangeRate` at the start of one epoch.
public struct SuiPoolExchangeRate: Sendable, Equatable, Codable {
    public let poolTokenAmount: UInt64
    public let suiAmount: UInt64

    public init(suiAmount: UInt64, poolTokenAmount: UInt64) {
        self.suiAmount = suiAmount
        self.poolTokenAmount = poolTokenAmount
    }

    /// The rate Move uses for a pool without history: 1:1.
    public static let initial = SuiPoolExchangeRate(suiAmount: 0, poolTokenAmount: 0)

    /// SUI value of `tokens` pool tokens. Move aborts when the result exceeds `u64`; this returns `nil`.
    public func suiAmount(forTokens tokens: UInt64) -> UInt64? {
        guard suiAmount != 0, poolTokenAmount != 0 else {
            return tokens
        }

        return UInt64(exactly: BigInt(suiAmount) * BigInt(tokens) / BigInt(poolTokenAmount))
    }

    /// Pool tokens issued for `sui` MIST. Move aborts when the result exceeds `u64`; this returns `nil`.
    public func tokenAmount(forSui sui: UInt64) -> UInt64? {
        guard suiAmount != 0, poolTokenAmount != 0 else {
            return sui
        }

        return UInt64(exactly: BigInt(poolTokenAmount) * BigInt(sui) / BigInt(suiAmount))
    }
}

/// Outcome of looking an exchange rate up in the epochs that were actually fetched.
public enum SuiRateLookup: Sendable, Equatable {
    /// The pool has no rate at that epoch; Move treats it as 1:1.
    case initial
    case rate(SuiPoolExchangeRate)
    /// The rate lies outside the fetched window, so no honest answer exists.
    case unavailable
}

/// What a read of a pool's exchange-rate table produced. An epoch is absent only when the node
/// said so explicitly; anything unreadable is listed apart, because it must not be skipped over.
public struct SuiPoolRateEntries: Sendable, Equatable {
    public let rates: [UInt64: SuiPoolExchangeRate]
    public let unreadable: Set<UInt64>

    public init(rates: [UInt64: SuiPoolExchangeRate], unreadable: Set<UInt64> = []) {
        self.rates = rates
        self.unreadable = unreadable
    }
}

public enum SuiStakingMath {
    /// `pool_token_exchange_rate_at_epoch`: before activation the rate is 1:1, a deactivated
    /// pool is clamped to its deactivation epoch, then the latest entry at or before that epoch wins.
    /// `fetched` is the epoch window `entries` was read for; walking below it yields `.unavailable`,
    /// and so does reaching an epoch in `unreadable`, since its entry may exist.
    public static func lookup(
        epoch: UInt64,
        activationEpoch: UInt64?,
        deactivationEpoch: UInt64?,
        entries: [UInt64: SuiPoolExchangeRate],
        unreadable: Set<UInt64> = [],
        fetched: ClosedRange<UInt64>
    ) -> SuiRateLookup {
        guard let activationEpoch, activationEpoch <= epoch else {
            return .initial
        }

        var current = min(epoch, deactivationEpoch ?? epoch)
        while current >= activationEpoch {
            if let rate = entries[current] {
                return .rate(rate)
            }

            guard !unreadable.contains(current) else {
                return .unavailable
            }

            guard current > fetched.lowerBound else {
                return .unavailable
            }

            current -= 1
        }

        return .initial
    }

    /// The epochs worth fetching to resolve `epoch`: the clamped epoch and a few below it, bounded by
    /// activation. `nil` when the pool is not yet active at `epoch`, where the rate is 1:1 and needs no read.
    public static func fetchWindow(
        epoch: UInt64, activationEpoch: UInt64?, deactivationEpoch: UInt64?, lookback: UInt64
    ) -> ClosedRange<UInt64>? {
        guard let activationEpoch, activationEpoch <= epoch else {
            return nil
        }

        let top = min(epoch, deactivationEpoch ?? epoch)
        let bottom = max(activationEpoch, top >= lookback ? top - lookback : 0)
        guard bottom <= top else {
            return nil
        }

        return bottom...top
    }

    /// The rate at `epoch` from `entries` (read for ``fetchWindow(epoch:activationEpoch:deactivationEpoch:lookback:)``),
    /// with the 1:1 initial rate when Move uses it. `nil` when the answer lies outside what was read.
    public static func rate(
        epoch: UInt64,
        activationEpoch: UInt64?,
        deactivationEpoch: UInt64?,
        entries: [UInt64: SuiPoolExchangeRate],
        unreadable: Set<UInt64> = [],
        lookback: UInt64
    ) -> SuiPoolExchangeRate? {
        let fetchable = fetchWindow(
            epoch: epoch, activationEpoch: activationEpoch, deactivationEpoch: deactivationEpoch, lookback: lookback
        )

        guard let window = fetchable else {
            return .initial
        }

        switch lookup(
            epoch: epoch,
            activationEpoch: activationEpoch,
            deactivationEpoch: deactivationEpoch,
            entries: entries,
            unreadable: unreadable,
            fetched: window
        ) {
        case .initial: return .initial
        case let .rate(rate): return rate
        case .unavailable: return nil
        }
    }

    /// `withdraw_rewards`: value of the stake's pool tokens at the current rate, minus principal,
    /// floored at zero and capped by what the rewards pool holds. `nil` when Move would abort.
    public static func estimatedReward(
        principal: UInt64,
        activationRate: SuiPoolExchangeRate,
        currentRate: SuiPoolExchangeRate,
        rewardsPool: UInt64
    ) -> UInt64? {
        guard
            let tokens = activationRate.tokenAmount(forSui: principal),
            let total = currentRate.suiAmount(forTokens: tokens)
        else {
            return nil
        }

        return min(total >= principal ? total - principal : 0, rewardsPool)
    }
}

/// A `0x3::staking_pool::StakingPool` as seen in the system state.
public struct SuiStakingPool: Sendable, Equatable, Codable {
    public let activationEpoch: UInt64?
    public let deactivationEpoch: UInt64?
    public let exchangeRatesTableId: String
    public let id: String
    public let rewardsPool: UInt64
    public let suiBalance: UInt64

    public init(
        id: String,
        activationEpoch: UInt64?,
        deactivationEpoch: UInt64?,
        rewardsPool: UInt64,
        suiBalance: UInt64,
        exchangeRatesTableId: String
    ) {
        self.id = id
        self.activationEpoch = activationEpoch
        self.deactivationEpoch = deactivationEpoch
        self.rewardsPool = rewardsPool
        self.suiBalance = suiBalance
        self.exchangeRatesTableId = exchangeRatesTableId
    }
}

/// An active validator that accepts stake.
public struct SuiValidator: Sendable, Equatable, Codable {
    public let address: String
    public let commissionBasisPoints: UInt64
    public let name: String
    public let pool: SuiStakingPool
    public let votingPower: UInt64

    public init(
        address: String, name: String, commissionBasisPoints: UInt64, votingPower: UInt64, pool: SuiStakingPool
    ) {
        self.address = address
        self.name = name
        self.commissionBasisPoints = commissionBasisPoints
        self.votingPower = votingPower
        self.pool = pool
    }
}

/// An owned `0x3::staking_pool::StakedSui` receipt.
public struct SuiStakedSui: Sendable, Equatable, Codable {
    public let activationEpoch: UInt64
    /// Base58, as the node reports it.
    public let digest: String
    public let objectId: String
    public let poolId: String
    public let principal: UInt64
    public let version: UInt64

    public init(
        objectId: String, version: UInt64, digest: String, poolId: String, activationEpoch: UInt64, principal: UInt64
    ) {
        self.objectId = objectId
        self.version = version
        self.digest = digest
        self.poolId = poolId
        self.activationEpoch = activationEpoch
        self.principal = principal
    }

    /// The object reference a transaction needs.
    public func reference() throws -> SuiObjectReference {
        SuiObjectReference(
            objectId: try Data(hexString: objectId), version: version, digest: try Base58.decode(digest)
        )
    }
}

/// Whether the pool behind a receipt is still in the active validator set.
public enum SuiPoolState: String, Sendable, Equatable, Codable {
    case active
    /// Confirmed to have left the active set: no longer earning, still withdrawable.
    case inactive
    /// The pool could not be looked up, so nothing is known about it.
    case unknown
}

/// Where a stake is in its life.
public enum SuiStakeStatus: String, Sendable, Equatable, Codable {
    /// Earning rewards since its activation epoch.
    case earning
    /// Activates at the start of a future epoch; withdrawing now returns principal only.
    case pending
    /// Its pool was deactivated: rewards stopped, and the stake can still be withdrawn.
    case retired

    /// A confirmed-inactive pool is retired whatever the epoch; with an unknown pool only the epoch is known.
    public static func status(activationEpoch: UInt64, epoch: UInt64, poolState: SuiPoolState) -> SuiStakeStatus {
        guard poolState != .inactive else {
            return .retired
        }

        return activationEpoch > epoch ? .pending : .earning
    }
}

/// One receipt with the validator and the estimated rewards it has accrued.
public struct SuiStakePosition: Sendable, Equatable, Codable {
    /// `nil` when the rewards read failed or the data was unavailable; the position stays usable.
    public let estimatedReward: UInt64?
    public let poolState: SuiPoolState
    public let stake: SuiStakedSui
    public let status: SuiStakeStatus
    public let validatorAddress: String?
    public let validatorName: String?

    public init(
        stake: SuiStakedSui,
        status: SuiStakeStatus,
        validatorAddress: String?,
        validatorName: String?,
        poolState: SuiPoolState,
        estimatedReward: UInt64?
    ) {
        self.stake = stake
        self.status = status
        self.validatorAddress = validatorAddress
        self.validatorName = validatorName
        self.poolState = poolState
        self.estimatedReward = estimatedReward
    }
}

/// Everything the staking UI shows for one account.
public struct SuiStakingRead: Sendable, Equatable, Codable {
    /// How long an epoch lasts, in milliseconds; `0` if unknown.
    public let epochDurationMs: UInt64
    public let epoch: UInt64
    /// When the current epoch began, in Unix milliseconds; `0` if unknown.
    public let epochStartTimestampMs: UInt64
    public let positions: [SuiStakePosition]
    public let validators: [SuiValidator]

    public init(
        epoch: UInt64,
        positions: [SuiStakePosition],
        validators: [SuiValidator],
        epochStartTimestampMs: UInt64 = 0,
        epochDurationMs: UInt64 = 0
    ) {
        self.epoch = epoch
        self.positions = positions
        self.validators = validators
        self.epochStartTimestampMs = epochStartTimestampMs
        self.epochDurationMs = epochDurationMs
    }

    public var totalPrincipal: UInt64 { positions.reduce(0) { $0 + $1.stake.principal } }

    /// `nil` unless every position has an estimate.
    public var totalEstimatedRewards: UInt64? {
        positions.reduce(UInt64?.some(0)) { sum, position in
            guard let sum, let reward = position.estimatedReward else {
                return nil
            }

            return sum + reward
        }
    }
}
