//
//  SolanaStaking.swift
//  WalletKit
//
//  Created by Andrey Yurkevich on 06/11/2026.
//  Copyright © 2026 Reefr Wallet. All rights reserved.
//

import Foundation

// MARK: - SolanaStakeDiscovery

/// How far a list of stake accounts can be trusted.
public enum SolanaStakeDiscovery: String, Codable, Sendable {
    /// `getProgramAccounts` answered for both authorities.
    case complete
    /// Built from known addresses and app seeds: others may exist.
    case degraded
}

// MARK: - SolanaStakingRead

/// A consistent read of an owner's stake accounts. ``history`` isn't stored; it is needed to
/// resolve rewards against the same snapshot.
public struct SolanaStakingRead: Sendable {
    public let accounts: [SolanaStakeAccount]
    public let clock: SolanaClock
    public let discovery: SolanaStakeDiscovery
    public let history: SolanaStakeHistory
    public let newRateEpoch: UInt64?
    public let schedule: SolanaEpochSchedule
    /// Measured seconds per slot, when the node's samples allowed it.
    public let slotDuration: Double?

    public init(
        accounts: [SolanaStakeAccount],
        clock: SolanaClock,
        discovery: SolanaStakeDiscovery,
        history: SolanaStakeHistory,
        newRateEpoch: UInt64?,
        schedule: SolanaEpochSchedule,
        slotDuration: Double?
    ) {
        self.accounts = accounts
        self.clock = clock
        self.discovery = discovery
        self.history = history
        self.newRateEpoch = newRateEpoch
        self.schedule = schedule
        self.slotDuration = slotDuration
    }

    public var positions: [SolanaStakePosition] {
        accounts.map { account in
            SolanaStakePosition(
                account: account,
                activation: account.delegation?.activation(
                    at: clock.epoch, history: history, newRateEpoch: newRateEpoch
                ) ?? SolanaStakeActivation(),
                status: account.status(at: clock.epoch, history: history, newRateEpoch: newRateEpoch)
            )
        }
    }

    public var slotsRemainingInEpoch: UInt64 {
        schedule.slotsRemaining(after: clock.slot)
    }

    /// Seconds per slot since the epoch started, for when the node has no samples.
    public func fallbackSlotDuration() -> Double? {
        let index = schedule.epochAndIndex(of: clock.slot).index
        let elapsed = clock.unixTimestamp - clock.epochStartTimestamp

        guard index >= Self.minimumFallbackSlots, elapsed > 0 else {
            return nil
        }

        return Double(elapsed) / Double(index)
    }

    /// Fewer slots than this make the elapsed time too noisy to extrapolate.
    private static let minimumFallbackSlots: UInt64 = 1_000
}

// MARK: - SolanaStakePosition

/// A stake account with its phase at the read's epoch.
public struct SolanaStakePosition: Codable, Equatable, Sendable {
    public let account: SolanaStakeAccount
    public let activation: SolanaStakeActivation
    public let status: SolanaStakeStatus

    public init(account: SolanaStakeAccount, activation: SolanaStakeActivation, status: SolanaStakeStatus) {
        self.account = account
        self.activation = activation
        self.status = status
    }

    /// `deactivate` and `split` need the staker; lockup doesn't block them.
    public func canUnstake(owner: String) -> Bool {
        account.staker == owner && (status == .active || status == .activating)
    }

    /// `withdraw` needs the withdrawer, a finished cooldown and no lockup.
    public func canWithdraw(owner: String, at clock: SolanaClock) -> Bool {
        account.withdrawer == owner && !account.isLocked(at: clock) && (status == .inactive || status == .undelegated)
    }
}

// MARK: - SolanaStakingRewards

/// What's known of one epoch's inflation rewards.
public struct SolanaStakingRewards: Codable, Equatable, Sendable {
    public let attemptedAt: Date
    public let epoch: UInt64
    public let lamports: UInt64
    public let queriedAddresses: [String]
    /// Addresses with a `null` result and no proof they earned nothing.
    public let unknownAddresses: [String]

    public init(
        attemptedAt: Date,
        epoch: UInt64,
        lamports: UInt64,
        queriedAddresses: [String],
        unknownAddresses: [String]
    ) {
        self.attemptedAt = attemptedAt
        self.epoch = epoch
        self.lamports = lamports
        self.queriedAddresses = queriedAddresses
        self.unknownAddresses = unknownAddresses
    }
}

// MARK: - SolanaValidator

/// A vote account stake can be delegated to. Names, logos and rates come from the indexer; the
/// node's own list has only commission and stake.
public struct SolanaValidator: Codable, Equatable, Identifiable, Sendable {
    /// Estimated annual percentage yield, in percent.
    public let apy: Decimal?
    public let commission: Int?
    public let imageURL: URL?
    public let isDelinquent: Bool
    public let name: String?
    public let voteAddress: String

    public var id: String { voteAddress }

    public init(
        apy: Decimal? = nil,
        commission: Int? = nil,
        imageURL: URL? = nil,
        isDelinquent: Bool = false,
        name: String? = nil,
        voteAddress: String
    ) {
        self.apy = apy
        self.commission = commission
        self.imageURL = imageURL
        self.isDelinquent = isDelinquent
        self.name = name
        self.voteAddress = voteAddress
    }
}

// MARK: - SolanaStakingAction

/// One atomic staking transaction. Amounts are lamports.
public enum SolanaStakingAction: Codable, Equatable, Sendable {
    /// A stake account to withdraw and the lamports it holds.
    public struct Withdrawal: Codable, Equatable, Sendable {
        public let address: String
        public let lamports: UInt64

        public init(address: String, lamports: UInt64) {
            self.address = address
            self.lamports = lamports
        }
    }

    case stake(lamports: UInt64, voter: String)
    case unstake(accounts: [String])
    case unstakePartial(account: String, lamports: UInt64)
    case withdraw([Withdrawal])
}

// MARK: - SolanaPreparedStaking

/// A built, unsigned staking transaction.
public struct SolanaPreparedStaking: Equatable, Sendable {
    public let action: SolanaStakingAction
    public let estimate: SolanaFeeEstimate
    /// Past this block height the transaction can never land.
    public let lastValidBlockHeight: UInt64
    /// Base58.
    public let recentBlockhash: String
    /// Rent the transaction funds, zero if it creates no account.
    public let rent: UInt64
    public let slotAtBuild: UInt64
    /// The ``SolanaUnsignedTransaction`` envelope.
    public let unsigned: Data

    public init(
        action: SolanaStakingAction,
        estimate: SolanaFeeEstimate,
        lastValidBlockHeight: UInt64,
        recentBlockhash: String,
        rent: UInt64,
        slotAtBuild: UInt64,
        unsigned: Data
    ) {
        self.action = action
        self.estimate = estimate
        self.lastValidBlockHeight = lastValidBlockHeight
        self.recentBlockhash = recentBlockhash
        self.rent = rent
        self.slotAtBuild = slotAtBuild
        self.unsigned = unsigned
    }
}

// MARK: - SolanaStakingBuildError

public enum SolanaStakingBuildError: Error, Equatable {
    /// `StakeError::EpochRewardsActive`: the program refuses stake changes while it pays out
    /// an epoch's rewards, for a while at the start of each epoch.
    case epochRewardsActive
    /// Simulation rejected the transaction; nothing was sent.
    case simulationFailed(String)
    case transactionTooLarge
}

// MARK: - SolanaSignatureStatus

/// What a node reports about a signature. Only `confirmed` or better resolves anything:
/// a `processed` block can be dropped with its fork.
public enum SolanaSignatureStatus: Equatable, Sendable {
    case confirmed
    case failed
    case notFound
    case processed
}

// MARK: - SolanaPendingSubmission

/// A signed staking transaction whose outcome isn't known yet, stored before it is broadcast.
public struct SolanaPendingSubmission: Codable, Equatable, Sendable {
    /// How far the finalized chain has been checked for the signature.
    public struct ExpiryCursor: Codable, Equatable, Sendable {
        public let blockhash: String
        public let height: UInt64
        public let slot: UInt64

        public init(blockhash: String, height: UInt64, slot: UInt64) {
            self.blockhash = blockhash
            self.height = height
            self.slot = slot
        }
    }

    public let action: SolanaStakingAction
    public let lastValidBlockHeight: UInt64
    public let recentBlockhash: String
    /// Base58; also the transaction id.
    public let signature: String
    public let slotAtBuild: UInt64

    public var cursor: ExpiryCursor?
    /// The blockhash has expired but nothing proves the transaction didn't land.
    public var isPastValidity: Bool

    public init(
        action: SolanaStakingAction,
        cursor: ExpiryCursor? = nil,
        isPastValidity: Bool = false,
        lastValidBlockHeight: UInt64,
        recentBlockhash: String,
        signature: String,
        slotAtBuild: UInt64
    ) {
        self.action = action
        self.cursor = cursor
        self.isPastValidity = isPastValidity
        self.lastValidBlockHeight = lastValidBlockHeight
        self.recentBlockhash = recentBlockhash
        self.signature = signature
        self.slotAtBuild = slotAtBuild
    }
}

// MARK: - SolanaSubmissionUpdate

/// What reconciling a ``SolanaPendingSubmission`` found out.
public enum SolanaSubmissionUpdate: Equatable, Sendable {
    case confirmed
    /// Landed and failed: changes reverted, fee charged.
    case failed
    /// Proven by walking the finalized chain: it never landed.
    case expired
    case unresolved(SolanaPendingSubmission)
}
