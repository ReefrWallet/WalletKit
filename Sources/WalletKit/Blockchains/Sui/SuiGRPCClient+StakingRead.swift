//
//  SuiGRPCClient+StakingRead.swift
//  WalletKit
//
//  Created by Andrey Yurkevich on 08/11/2026.
//  Copyright © 2026 Reefr Wallet. All rights reserved.
//
//  The combined staking read, plus the two-hop lookup of pools whose
//  validator left the active set (`inactive_validators` table ->
//  `ValidatorWrapper` -> `Versioned` -> `Validator`).

import Foundation
import GRPCCore
import SwiftProtobuf
import WalletKitGRPC

/// A pool from the `inactive_validators` table, with what its validator was called.
struct SuiInactivePool: Sendable, Equatable {
    let pool: SuiStakingPool
    let validatorAddress: String?
    let validatorName: String?
}

extension SuiGRPCClient {
    /// Reads `owner`'s stakes and the validators they sit with. Rewards are read last and
    /// separately: an unreadable rate leaves only the affected stakes without an estimate.
    public func stakingRead(of owner: SuiAddress) async throws -> SuiStakingRead {
        async let systemRead = stakingSystemState()
        async let stakesRead = stakedSuiObjects(of: owner)
        let (system, stakes) = try await (systemRead, stakesRead)

        var pools: [String: SuiStakingPool] = [:]
        var validatorsByPool: [String: SuiValidator] = [:]
        for validator in system.validators {
            pools[validator.pool.id] = validator.pool
            validatorsByPool[validator.pool.id] = validator
        }

        let missing = Set(stakes.map(\.poolId)).subtracting(pools.keys)
        var inactive: [String: SuiInactivePool] = [:]
        if !missing.isEmpty {
            inactive = (try? await inactivePools(table: system.inactiveValidatorsTableId, wanting: missing)) ?? [:]
            for (poolId, entry) in inactive {
                pools[poolId] = entry.pool
            }
        }

        let rewards = await estimatedRewards(for: stakes, pools: pools, epoch: system.epoch)

        let positions = stakes.map { stake -> SuiStakePosition in
            let active = validatorsByPool[stake.poolId]
            let former = inactive[stake.poolId]
            // Inactive only when the table itself listed the pool; a failed or empty lookup stays unknown.
            let poolState: SuiPoolState = active != nil ? .active : (former != nil ? .inactive : .unknown)
            return SuiStakePosition(
                stake: stake,
                status: SuiStakeStatus.status(
                    activationEpoch: stake.activationEpoch, epoch: system.epoch, poolState: poolState
                ),
                validatorAddress: active?.address ?? former?.validatorAddress,
                validatorName: active?.name ?? former?.validatorName,
                poolState: poolState,
                estimatedReward: rewards[stake.objectId]
            )
        }

        return SuiStakingRead(
            epoch: system.epoch,
            positions: positions.sorted { $0.stake.principal > $1.stake.principal },
            validators: system.validators,
            epochStartTimestampMs: system.epochStartTimestampMs,
            epochDurationMs: system.epochDurationMs
        )
    }

    /// Looks up pools of validators that left the active set, by pool id.
    func inactivePools(table: String, wanting poolIds: Set<String>) async throws -> [String: SuiInactivePool] {
        try await withStateServiceClient { client in
            var found: [String: SuiInactivePool] = [:]
            var pageToken = Data()

            repeat {
                let page = Sui_Rpc_V2_ListDynamicFieldsRequest.with {
                    $0.parent = table
                    $0.pageSize = 1000
                    $0.readMask = Google_Protobuf_FieldMask.with { $0.paths = ["field_object.json"] }
                    if !pageToken.isEmpty {
                        $0.pageToken = pageToken
                    }
                }

                let response = try await rpc(.read) {
                    try await client.listDynamicFields(
                        request: ClientRequest(message: page),
                        options: self.callOptions
                    )
                }

                for field in response.dynamicFields {
                    let json = field.fieldObject.json
                    guard
                        let poolId = json.field("name")?.string,
                        poolIds.contains(poolId),
                        let versionedId = json.field("value")?.field("inner")?.field("id")?.string
                    else {
                        continue
                    }

                    let inner = try await rpc(.read) {
                        try await client.listDynamicFields(
                            request: ClientRequest(message: Sui_Rpc_V2_ListDynamicFieldsRequest.with {
                                $0.parent = versionedId
                                $0.pageSize = 10
                                $0.readMask = Google_Protobuf_FieldMask.with {
                                    $0.paths = ["value_type", "field_object.json"]
                                }
                            }),
                            options: self.callOptions
                        )
                    }

                    for candidate in inner.dynamicFields where candidate.valueType.hasSuffix("::validator::Validator") {
                        if let entry = Self.inactivePool(from: candidate.fieldObject.json) {
                            found[poolId] = entry
                        }
                    }
                }

                pageToken = response.nextPageToken
            } while !pageToken.isEmpty && found.count < poolIds.count

            return found
        }
    }

    static func inactivePool(from field: Google_Protobuf_Value) -> SuiInactivePool? {
        guard
            let validator = field.field("value"),
            let pool = validator.field("staking_pool"),
            let id = pool.field("id")?.string,
            let tableId = pool.field("exchange_rates")?.field("id")?.string,
            let rewardsPool = pool.field("rewards_pool")?.u64,
            let suiBalance = pool.field("sui_balance")?.u64
        else {
            return nil
        }

        let metadata = validator.field("metadata")
        return SuiInactivePool(
            pool: SuiStakingPool(
                id: id,
                activationEpoch: pool.field("activation_epoch")?.u64,
                deactivationEpoch: pool.field("deactivation_epoch")?.u64,
                rewardsPool: rewardsPool,
                suiBalance: suiBalance,
                exchangeRatesTableId: tableId
            ),
            validatorAddress: metadata?.field("sui_address")?.string,
            validatorName: metadata?.field("name")?.string
        )
    }
}

extension Google_Protobuf_Value {
    func field(_ name: String) -> Google_Protobuf_Value? {
        guard case let .structValue(content)? = kind else {
            return nil
        }

        return content.fields[name]
    }

    var string: String? {
        guard case let .stringValue(value)? = kind else {
            return nil
        }

        return value
    }

    /// A `u64` the node renders as a decimal string (Move `Option::None` arrives as null, so `nil`).
    var u64: UInt64? {
        string.flatMap { UInt64($0) }
    }
}
