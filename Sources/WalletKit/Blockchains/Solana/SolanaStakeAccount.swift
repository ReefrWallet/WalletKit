//
//  SolanaStakeAccount.swift
//  WalletKit
//
//  Created by Andrey Yurkevich on 06/11/2026.
//  Copyright © 2026 Reefr Wallet. All rights reserved.
//

import Foundation

// MARK: - SolanaStakeAccount

/// An account of the native Stake program, parsed from its 200-byte layout.
public struct SolanaStakeAccount: Codable, Equatable, Sendable {
    /// The stake delegated to a vote account.
    public struct Delegation: Codable, Equatable, Sendable {
        /// `UInt64.max` for bootstrap stake.
        public let activationEpoch: UInt64
        /// `UInt64.max` if not deactivated.
        public let deactivationEpoch: UInt64
        public let stake: UInt64
        public let voter: String

        public init(activationEpoch: UInt64, deactivationEpoch: UInt64, stake: UInt64, voter: String) {
            self.activationEpoch = activationEpoch
            self.deactivationEpoch = deactivationEpoch
            self.stake = stake
            self.voter = voter
        }
    }

    /// Withdrawal is blocked until both have passed, unless the custodian signs.
    public struct Lockup: Codable, Equatable, Sendable {
        public let custodian: String
        public let epoch: UInt64
        public let unixTimestamp: Int64

        public init(custodian: String, epoch: UInt64, unixTimestamp: Int64) {
            self.custodian = custodian
            self.epoch = epoch
            self.unixTimestamp = unixTimestamp
        }
    }

    public let address: String
    /// `nil` for an account that was initialized but never delegated.
    public let delegation: Delegation?
    public let lamports: UInt64
    public let lockup: Lockup
    public let rentExemptReserve: UInt64
    public let staker: String
    public let withdrawer: String

    public init(
        address: String,
        delegation: Delegation?,
        lamports: UInt64,
        lockup: Lockup,
        rentExemptReserve: UInt64,
        staker: String,
        withdrawer: String
    ) {
        self.address = address
        self.delegation = delegation
        self.lamports = lamports
        self.lockup = lockup
        self.rentExemptReserve = rentExemptReserve
        self.staker = staker
        self.withdrawer = withdrawer
    }

    /// Parses a Stake program account's `data`.
    ///
    /// - Returns: `nil` for an uninitialized account, a rewards pool, or data too short to be
    ///   a stake account.
    public init?(address: String, lamports: UInt64, data: Data) {
        var reader = SolanaByteReader(data)

        guard
            data.count >= StakeProgram.accountSize,
            let state = reader.uint32(),
            state == 1 || state == 2,
            let reserve = reader.uint64(),
            let staker = reader.address(),
            let withdrawer = reader.address(),
            let unixTimestamp = reader.int64(),
            let lockupEpoch = reader.uint64(),
            let custodian = reader.address()
        else {
            return nil
        }

        self.address = address
        self.lamports = lamports
        lockup = Lockup(custodian: custodian, epoch: lockupEpoch, unixTimestamp: unixTimestamp)
        rentExemptReserve = reserve
        self.staker = staker
        self.withdrawer = withdrawer

        guard state == 2 else {
            delegation = nil
            return
        }

        guard
            let voter = reader.address(),
            let stake = reader.uint64(),
            let activation = reader.uint64(),
            let deactivation = reader.uint64()
        else {
            return nil
        }

        delegation = Delegation(
            activationEpoch: activation,
            deactivationEpoch: deactivation,
            stake: stake,
            voter: voter
        )
    }

    /// Whether the lockup still blocks withdrawal at `clock`. Custodian signatures aren't supported.
    public func isLocked(at clock: SolanaClock) -> Bool {
        lockup.unixTimestamp > clock.unixTimestamp || lockup.epoch > clock.epoch
    }
}

// MARK: - SolanaClock

/// The Clock sysvar.
public struct SolanaClock: Codable, Equatable, Sendable {
    public let epoch: UInt64
    public let epochStartTimestamp: Int64
    public let slot: UInt64
    public let unixTimestamp: Int64

    public init(epoch: UInt64, epochStartTimestamp: Int64, slot: UInt64, unixTimestamp: Int64) {
        self.epoch = epoch
        self.epochStartTimestamp = epochStartTimestamp
        self.slot = slot
        self.unixTimestamp = unixTimestamp
    }

    init?(data: Data) {
        var reader = SolanaByteReader(data)

        guard
            let slot = reader.uint64(),
            let epochStart = reader.int64(),
            let epoch = reader.uint64(),
            reader.uint64() != nil, // leader_schedule_epoch
            let unixTimestamp = reader.int64()
        else {
            return nil
        }

        self.init(epoch: epoch, epochStartTimestamp: epochStart, slot: slot, unixTimestamp: unixTimestamp)
    }
}

// MARK: - SolanaEpochSchedule

/// The cluster's epoch lengths, including the shorter warmup epochs of test clusters.
public struct SolanaEpochSchedule: Codable, Equatable, Sendable {
    private static let minimumSlotsPerEpoch: UInt64 = 32

    public let firstNormalEpoch: UInt64
    public let firstNormalSlot: UInt64
    public let slotsPerEpoch: UInt64

    public init(firstNormalEpoch: UInt64, firstNormalSlot: UInt64, slotsPerEpoch: UInt64) {
        self.firstNormalEpoch = firstNormalEpoch
        self.firstNormalSlot = firstNormalSlot
        self.slotsPerEpoch = slotsPerEpoch
    }

    /// The epoch containing `slot` and the slot's index within it.
    public func epochAndIndex(of slot: UInt64) -> (epoch: UInt64, index: UInt64) {
        guard slot < firstNormalSlot else {
            let normal = slot - firstNormalSlot
            return (firstNormalEpoch + normal / slotsPerEpoch, normal % slotsPerEpoch)
        }

        var epoch: UInt64 = 0
        var first: UInt64 = 0

        while slot >= first + Self.minimumSlotsPerEpoch << epoch {
            first += Self.minimumSlotsPerEpoch << epoch
            epoch += 1
        }

        return (epoch, slot - first)
    }

    public func slotsInEpoch(_ epoch: UInt64) -> UInt64 {
        epoch < firstNormalEpoch ? Self.minimumSlotsPerEpoch << epoch : slotsPerEpoch
    }

    /// Slots until the epoch after the one containing `slot` starts.
    public func slotsRemaining(after slot: UInt64) -> UInt64 {
        let (epoch, index) = epochAndIndex(of: slot)
        return slotsInEpoch(epoch) - index
    }
}

// MARK: - SolanaStakeHistory

/// The StakeHistory sysvar, as bincode `Vec<(Epoch, StakeHistoryEntry)>`, newest first.
public struct SolanaStakeHistory: Equatable, Sendable {
    /// The cluster's stake in one epoch.
    public struct Entry: Equatable, Sendable {
        public let activating: UInt64
        public let deactivating: UInt64
        public let effective: UInt64

        public init(activating: UInt64, deactivating: UInt64, effective: UInt64) {
            self.activating = activating
            self.deactivating = deactivating
            self.effective = effective
        }
    }

    let entries: [UInt64: Entry]
    /// The newest epoch recorded, `nil` when empty.
    public let newestEpoch: UInt64?

    public init(entries: [UInt64: Entry]) {
        self.entries = entries
        newestEpoch = entries.keys.max()
    }

    /// - Returns: `nil` for data that isn't a well-formed history.
    public init?(data: Data) {
        var reader = SolanaByteReader(data)

        guard let count = reader.uint64(), count <= data.count / 32 else {
            return nil
        }

        var entries: [UInt64: Entry] = [:]

        for _ in 0..<count {
            guard
                let epoch = reader.uint64(),
                let effective = reader.uint64(),
                let activating = reader.uint64(),
                let deactivating = reader.uint64()
            else {
                return nil
            }

            entries[epoch] = Entry(activating: activating, deactivating: deactivating, effective: effective)
        }

        self.init(entries: entries)
    }

    public func entry(_ epoch: UInt64) -> Entry? {
        entries[epoch]
    }
}

// MARK: - SolanaByteReader

/// Reads little-endian fields in order; each returns `nil` past the end.
struct SolanaByteReader {
    private let bytes: [UInt8]
    private var offset = 0

    init(_ data: Data) {
        bytes = [UInt8](data)
    }

    mutating func address() -> String? {
        guard let raw = take(32) else {
            return nil
        }

        return Base58.encode(Data(raw))
    }

    mutating func int64() -> Int64? {
        uint64().map { Int64(bitPattern: $0) }
    }

    mutating func uint32() -> UInt32? {
        take(4).map { $0.reversed().reduce(UInt32(0)) { $0 << 8 | UInt32($1) } }
    }

    mutating func uint64() -> UInt64? {
        take(8).map { $0.reversed().reduce(UInt64(0)) { $0 << 8 | UInt64($1) } }
    }

    private mutating func take(_ count: Int) -> ArraySlice<UInt8>? {
        guard offset + count <= bytes.count else {
            return nil
        }

        defer { offset += count }
        return bytes[offset..<(offset + count)]
    }
}
