//
//  SuiGRPCClient+Staking.swift
//  WalletKit
//
//  Created by Andrey Yurkevich on 08/11/2026.
//  Copyright © 2026 Reefr Wallet. All rights reserved.
//
//  Staking reads. Positions and rewards are separate reads: a receipt stays
//  visible even when its reward estimate cannot be computed.

import Foundation
import GRPCCore
import SwiftProtobuf
import WalletKitGRPC

/// The staking-relevant part of the current system state.
public struct SuiStakingSystemState: Sendable, Equatable {
    public let epoch: UInt64
    public let epochDurationMs: UInt64
    public let epochStartTimestampMs: UInt64
    /// The table holding pools of validators that left the active set.
    public let inactiveValidatorsTableId: String
    public let validators: [SuiValidator]
}

/// `derive_dynamic_field_id` for a `u64`-keyed field.
enum SuiDynamicFieldId {
    /// Blake2b-256 of `0xf0 || parent || len(key) as u64 LE || key || bcs(key type tag)`.
    static func derive(parent: Data, key: Data, keyTypeTag: Data) -> Data {
        Blake2b256.hash(Data([0xF0]) + parent + BCS.u64(UInt64(key.count)) + key + keyTypeTag)
    }

    static func epochKey(table: Data, epoch: UInt64) -> Data {
        derive(parent: table, key: BCS.u64(epoch), keyTypeTag: Data([0x02]))
    }
}

extension SuiGRPCClient {
    private static let stakedSuiType = "0x3::staking_pool::StakedSui"
    /// How many epochs below the one asked for are read when the exact entry is missing.
    private static let rateLookbackEpochs: UInt64 = 7
    private static let maxBatch = 50

    // MARK: - System state

    /// Reads the epoch, the active validators with their pools, and the inactive-pool table.
    public func stakingSystemState() async throws -> SuiStakingSystemState {
        try await withLedgerServiceClient { ledger in
            let request = Sui_Rpc_V2_GetEpochRequest.with {
                $0.readMask = Google_Protobuf_FieldMask.with {
                    $0.paths = [
                        "epoch",
                        "system_state.epoch",
                        "system_state.epoch_start_timestamp_ms",
                        "system_state.parameters.epoch_duration_ms",
                        "system_state.validators.active_validators.name",
                        "system_state.validators.active_validators.address",
                        "system_state.validators.active_validators.commission_rate",
                        "system_state.validators.active_validators.voting_power",
                        "system_state.validators.active_validators.staking_pool",
                        "system_state.validators.inactive_validators"
                    ]
                }
            }

            let response = try await rpc(.read) {
                try await ledger.getEpoch(
                    request: ClientRequest(message: request),
                    options: self.callOptions
                )
            }

            let state = response.epoch.systemState
            let validators = state.validators.activeValidators.map { validator in
                SuiValidator(
                    address: validator.address,
                    name: validator.name,
                    commissionBasisPoints: validator.commissionRate,
                    votingPower: validator.votingPower,
                    pool: Self.pool(from: validator.stakingPool)
                )
            }

            return SuiStakingSystemState(
                epoch: state.epoch,
                epochDurationMs: state.parameters.epochDurationMs,
                epochStartTimestampMs: state.epochStartTimestampMs,
                inactiveValidatorsTableId: state.validators.inactiveValidators.id,
                validators: validators
            )
        }
    }

    private static func pool(from pool: Sui_Rpc_V2_StakingPool) -> SuiStakingPool {
        SuiStakingPool(
            id: pool.id,
            activationEpoch: pool.hasActivationEpoch ? pool.activationEpoch : nil,
            deactivationEpoch: pool.hasDeactivationEpoch ? pool.deactivationEpoch : nil,
            rewardsPool: pool.rewardsPool,
            suiBalance: pool.suiBalance,
            exchangeRatesTableId: pool.exchangeRates.id
        )
    }

    // MARK: - Positions

    /// Every `StakedSui` receipt `owner` holds, across all pages.
    public func stakedSuiObjects(of owner: SuiAddress) async throws -> [SuiStakedSui] {
        try await withStateServiceClient { stateClient in
            var stakes: [SuiStakedSui] = []
            var pageToken = Data()

            repeat {
                let request = Sui_Rpc_V2_ListOwnedObjectsRequest.with {
                    $0.owner = owner.string
                    $0.objectType = Self.stakedSuiType
                    $0.readMask = Google_Protobuf_FieldMask.with {
                        $0.paths = ["object_id", "version", "digest", "contents"]
                    }

                    if !pageToken.isEmpty {
                        $0.pageToken = pageToken
                    }
                }

                let response = try await rpc(.read) {
                    try await stateClient.listOwnedObjects(
                        request: ClientRequest(message: request),
                        options: self.callOptions
                    )
                }

                for object in response.objects {
                    stakes.append(try Self.stakedSui(from: object))
                }

                pageToken = response.nextPageToken
            } while !pageToken.isEmpty

            return stakes
        }
    }

    /// `StakedSui { id: UID, pool_id: ID, stake_activation_epoch: u64, principal: Balance<SUI> }`.
    static func stakedSui(from object: Sui_Rpc_V2_Object) throws -> SuiStakedSui {
        let bytes = object.contents.value
        guard bytes.count == 80 else {
            throw BlockchainClientError.decodingFailed(reason: "StakedSui has \(bytes.count) bytes, expected 80")
        }

        let start = bytes.startIndex
        return SuiStakedSui(
            objectId: object.objectID,
            version: object.version,
            digest: object.digest,
            poolId: Data(bytes[(start + 32)..<(start + 64)]).hexEncoded,
            activationEpoch: littleEndianU64(bytes, at: start + 64),
            principal: littleEndianU64(bytes, at: start + 72)
        )
    }

    static func littleEndianU64(_ data: Data, at index: Data.Index) -> UInt64 {
        (0..<8).reduce(UInt64(0)) { $0 | UInt64(data[index + $1]) << UInt64(8 * $1) }
    }

    // MARK: - Exchange rates

    /// How one exchange-rate field object came back.
    enum RateObjectOutcome: Equatable {
        /// The node explicitly reported the object as nonexistent: the epoch has no entry.
        case notFound
        case rate(SuiPoolExchangeRate)
        /// Any other error, or contents that are not a `Field<u64, PoolTokenExchangeRate>`: the entry may exist.
        case unreadable
    }

    /// gRPC `NOT_FOUND`.
    private static let notFoundCode: Int32 = 5

    /// `Field<u64, PoolTokenExchangeRate>` is `id (32) | epoch (8) | sui_amount (8) | pool_token_amount (8)`.
    static func rateOutcome(_ result: Sui_Rpc_V2_GetObjectResult) -> RateObjectOutcome {
        switch result.result {
        case let .object(object)?:
            let contents = object.contents.value
            guard contents.count == 56 else {
                return .unreadable
            }

            let base = contents.startIndex + 40
            return .rate(
                SuiPoolExchangeRate(
                    suiAmount: littleEndianU64(contents, at: base),
                    poolTokenAmount: littleEndianU64(contents, at: base + 8)
                )
            )

        case let .error(status)?:
            return status.code == notFoundCode ? .notFound : .unreadable
        case nil:
            return .unreadable
        }
    }

    /// Reads the `PoolTokenExchangeRate` entries of `table` for `epochs`. Only an explicit `NOT_FOUND`
    /// counts as "no entry"; anything else the node returned for an epoch is reported as unreadable.
    func exchangeRates(table: String, epochs: Set<UInt64>) async throws -> SuiPoolRateEntries {
        let tableBytes = try Data(hexString: table)
        let ordered = epochs.sorted()
        let ids = ordered.map { SuiDynamicFieldId.epochKey(table: tableBytes, epoch: $0).hexEncoded }
        var rates: [UInt64: SuiPoolExchangeRate] = [:]
        var unreadable: Set<UInt64> = []

        for start in stride(from: 0, to: ids.count, by: Self.maxBatch) {
            let end = min(start + Self.maxBatch, ids.count)
            let results = try await batchResults(ids: Array(ids[start..<end]))
            let chunk = Self.rateEntries(epochs: Array(ordered[start..<end]), results: results)
            rates.merge(chunk.rates) { $1 }
            unreadable.formUnion(chunk.unreadable)
        }

        return SuiPoolRateEntries(rates: rates, unreadable: unreadable)
    }

    /// Maps one batch response onto the epochs it was requested for. Results are matched by position, so a
    /// response without exactly one result per request cannot be trusted at all: every epoch is unreadable.
    static func rateEntries(epochs: [UInt64], results: [Sui_Rpc_V2_GetObjectResult]) -> SuiPoolRateEntries {
        guard results.count == epochs.count else {
            return SuiPoolRateEntries(rates: [:], unreadable: Set(epochs))
        }

        var rates: [UInt64: SuiPoolExchangeRate] = [:]
        var unreadable: Set<UInt64> = []
        for (epoch, result) in zip(epochs, results) {
            switch rateOutcome(result) {
            case let .rate(rate): rates[epoch] = rate
            case .unreadable: unreadable.insert(epoch)
            case .notFound: break
            }
        }

        return SuiPoolRateEntries(rates: rates, unreadable: unreadable)
    }

    /// One result per requested id, in order.
    private func batchResults(ids: [String]) async throws -> [Sui_Rpc_V2_GetObjectResult] {
        try await withLedgerServiceClient { client in
            let request = Sui_Rpc_V2_BatchGetObjectsRequest.with {
                $0.requests = ids.map { id in
                    Sui_Rpc_V2_GetObjectRequest.with { $0.objectID = id }
                }

                // The batch-level mask applies to every request; per-request masks are ignored.
                $0.readMask = Google_Protobuf_FieldMask.with { $0.paths = ["object_id", "contents"] }
            }

            let response = try await rpc(.read) {
                try await client.batchGetObjects(
                    request: ClientRequest(message: request),
                    options: self.callOptions
                )
            }

            return response.objects
        }
    }

    // MARK: - Rewards

    /// The epochs to read per exchange-rate table: each stake's activation epoch and the current one.
    private static func rateEpochsNeeded(
        for stakes: [SuiStakedSui], pools: [String: SuiStakingPool], epoch: UInt64
    ) -> [String: Set<UInt64>] {
        var wanted: [String: Set<UInt64>] = [:]
        for stake in stakes {
            guard let pool = pools[stake.poolId] else {
                continue
            }

            for target in [stake.activationEpoch, epoch] {
                let window = SuiStakingMath.fetchWindow(
                    epoch: target,
                    activationEpoch: pool.activationEpoch,
                    deactivationEpoch: pool.deactivationEpoch,
                    lookback: rateLookbackEpochs
                )

                if let window {
                    wanted[pool.exchangeRatesTableId, default: []].formUnion(window)
                }
            }
        }

        return wanted
    }

    /// Estimated accrued rewards by `StakedSui` object id. A stake whose rates could not be read is omitted,
    /// while stakes on pools that were read fine keep their estimates.
    public func estimatedRewards(
        for stakes: [SuiStakedSui], pools: [String: SuiStakingPool], epoch: UInt64
    ) async -> [String: UInt64] {
        var fetched: [String: SuiPoolRateEntries] = [:]
        for (table, epochs) in Self.rateEpochsNeeded(for: stakes, pools: pools, epoch: epoch) {
            // A failed table read leaves every epoch of that table unreadable, not absent.
            fetched[table] = (try? await exchangeRates(table: table, epochs: epochs))
                ?? SuiPoolRateEntries(rates: [:], unreadable: epochs)
        }

        var rewards: [String: UInt64] = [:]
        for stake in stakes {
            guard let pool = pools[stake.poolId] else {
                continue
            }

            let entries = fetched[pool.exchangeRatesTableId] ?? SuiPoolRateEntries(rates: [:])
            func rate(at target: UInt64) -> SuiPoolExchangeRate? {
                SuiStakingMath.rate(
                    epoch: target,
                    activationEpoch: pool.activationEpoch,
                    deactivationEpoch: pool.deactivationEpoch,
                    entries: entries.rates,
                    unreadable: entries.unreadable,
                    lookback: Self.rateLookbackEpochs
                )
            }

            guard let activationRate = rate(at: stake.activationEpoch), let currentRate = rate(at: epoch) else {
                continue
            }

            rewards[stake.objectId] = SuiStakingMath.estimatedReward(
                principal: stake.principal,
                activationRate: activationRate,
                currentRate: currentRate,
                rewardsPool: pool.rewardsPool
            )
        }

        return rewards
    }
}
