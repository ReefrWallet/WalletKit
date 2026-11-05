//
//  TronClient+Staking.swift
//  WalletKit
//
//  Created by Andrey Yurkevich on 05/11/2026.
//  Copyright © 2026 Reefr Wallet. All rights reserved.
//

import Foundation

/// An account's Stake 2.0 position, as read from a Tron node.
public struct TronStakingState: Equatable, Sendable {
    /// TRX (in SUN) staked for one resource.
    public struct Frozen: Equatable, Sendable {
        public let amount: UInt64
        public let resource: TronRawTransaction.Resource

        public init(amount: UInt64, resource: TronRawTransaction.Resource) {
            self.amount = amount
            self.resource = resource
        }
    }

    /// An unstake waiting out its 14 days (or past them, until withdrawn).
    public struct Unfrozen: Equatable, Sendable {
        public let amount: UInt64
        public let expiration: Date
        public let resource: TronRawTransaction.Resource

        public init(amount: UInt64, expiration: Date, resource: TronRawTransaction.Resource) {
            self.amount = amount
            self.expiration = expiration
            self.resource = resource
        }
    }

    /// One resource's remaining and total allowance for the day.
    public struct Usage: Equatable, Sendable {
        public let limit: UInt64
        public let remaining: UInt64

        public init(limit: UInt64, remaining: UInt64) {
            self.limit = limit
            self.remaining = remaining
        }
    }

    /// Network-wide totals that convert staked TRX into resource units.
    public struct NetworkWeights: Equatable, Sendable {
        public let energyLimit: UInt64
        public let energyWeight: UInt64
        public let netLimit: UInt64
        public let netWeight: UInt64

        public init(energyLimit: UInt64, energyWeight: UInt64, netLimit: UInt64, netWeight: UInt64) {
            self.energyLimit = energyLimit
            self.energyWeight = energyWeight
            self.netLimit = netLimit
            self.netWeight = netWeight
        }
    }

    public let bandwidth: Usage
    /// SUN staked and delegated to other accounts: no longer unstakable, but still the owner's votes.
    public let delegated: UInt64
    public let energy: Usage
    public let frozen: [Frozen]
    /// SUN claimable with ``TronRawTransaction/Contract/withdrawBalance(owner:)``.
    public let rewards: UInt64
    public let unfrozen: [Unfrozen]
    public let votes: [TronRawTransaction.Vote]
    public let weights: NetworkWeights
    /// The node's total voting power, when it reports one (it counts delegated stake).
    public let votingPower: UInt64?
    /// SUN past their waiting period, claimable with
    /// ``TronRawTransaction/Contract/withdrawExpireUnfreeze(owner:)``.
    public let withdrawable: UInt64

    public init(
        bandwidth: Usage,
        energy: Usage,
        frozen: [Frozen],
        rewards: UInt64,
        unfrozen: [Unfrozen],
        votes: [TronRawTransaction.Vote],
        weights: NetworkWeights,
        withdrawable: UInt64,
        delegated: UInt64 = 0,
        votingPower: UInt64? = nil
    ) {
        self.bandwidth = bandwidth
        self.delegated = delegated
        self.votingPower = votingPower
        self.energy = energy
        self.frozen = frozen
        self.rewards = rewards
        self.unfrozen = unfrozen
        self.votes = votes
        self.weights = weights
        self.withdrawable = withdrawable
    }

    /// Votes cast, which can't exceed ``votePower``.
    public var assignedVotes: UInt64 {
        votes.reduce(0) { $0.addingReportingOverflow($1.count).overflow ? .max : $0 + $1.count }
    }

    /// One vote per staked TRX, whichever resource it is staked for and including
    /// stake delegated to other accounts, which keeps its voting rights with the owner.
    public var votePower: UInt64 {
        votingPower ?? (totalStaked + delegated) / Self.sunPerTRX
    }

    /// Staked SUN across resources.
    public var totalStaked: UInt64 {
        frozen.reduce(0) { $0 + $1.amount }
    }

    public func staked(for resource: TronRawTransaction.Resource) -> UInt64 {
        frozen.filter { $0.resource == resource }.reduce(0) { $0 + $1.amount }
    }

    /// Resource units `sun` of `resource` yields (or costs when unstaked):
    /// its share of the network's daily limit by staked weight. Approximate,
    /// as the weights move with every stake.
    public func resourceUnits(sun: UInt64, resource: TronRawTransaction.Resource) -> UInt64 {
        let (limit, weight): (UInt64, UInt64) = switch resource {
        case .bandwidth: (weights.netLimit, weights.netWeight)
        case .energy: (weights.energyLimit, weights.energyWeight)
        case .tronPower: (0, 0)
        }

        guard weight > 0 else {
            return 0
        }

        let units = Double(sun) / Double(Self.sunPerTRX) * Double(limit) / Double(weight)
        return UInt64(max(0, units.rounded(.down)))
    }

    static let sunPerTRX: UInt64 = 1_000_000
}

/// A representative (super representative or candidate) votes can go to.
public struct TronRepresentative: Equatable, Identifiable, Sendable {
    public let address: TronAddress
    /// Annualized voter reward in percent, when the indexer knows it.
    public let apr: Decimal?
    public let name: String?
    public let url: String?
    public let voteCount: UInt64

    public var id: String { address.string }

    public init(address: TronAddress, apr: Decimal? = nil, name: String? = nil, url: String? = nil, voteCount: UInt64) {
        self.address = address
        self.apr = apr
        self.name = name
        self.url = url
        self.voteCount = voteCount
    }
}

public extension TronClient {
    /// Asks the node to build `contract` (a Stake 2.0, vote or claim
    /// contract) and returns the unsigned `{txID, raw_data, raw_data_hex}`
    /// JSON the signers accept. The node's bytes are decoded and must hold
    /// exactly `contract`, so a misbehaving node can't swap what is signed.
    func buildStakingTransaction(_ contract: TronRawTransaction.Contract) async throws -> Data {
        let (path, body) = try Self.stakingRequest(contract)
        let data = try await relay(path: path, body: JSONSerialization.data(withJSONObject: body))
        let response = try JSONSerialization.jsonObject(with: data) as? [String: Any] ?? [:]

        guard let hex = response["raw_data_hex"] as? String else {
            let reason = (response["Error"] as? String) ?? Self.rejectionReason(response)
            throw WalletKitError.internalError(message: "Tron node did not construct a transaction: \(reason)")
        }

        guard try TronRawTransaction(rawBytes: Data(hexString: hex)).contract == contract else {
            throw WalletKitError.internalError(message: "Tron node built a different transaction than requested.")
        }

        return data
    }

    /// Candidates and super representatives, most voted first. Names and
    /// rewards come from TronScan; without it (or if it fails) the node's own
    /// list is used, which has neither.
    func representatives() async throws -> [TronRepresentative] {
        if let indexed = try? await indexedRepresentatives(), !indexed.isEmpty {
            return indexed
        }

        let response = try await stakingObject("wallet/listwitnesses", [:])

        return (response["witnesses"] as? [[String: Any]] ?? [])
            .compactMap { witness -> TronRepresentative? in
                guard
                    let hex = witness["address"] as? String,
                    let address = try? TronAddress(rawBytes: Data(hexString: hex))
                else {
                    return nil
                }

                return TronRepresentative(
                    address: address,
                    url: (witness["url"] as? String).flatMap { $0.isEmpty ? nil : $0 },
                    voteCount: Self.number(witness["voteCount"]) ?? 0
                )
            }
            .sorted { $0.voteCount > $1.voteCount }
    }

    /// Reads `owner`'s stake, resources, votes, unstakes and claimable amounts.
    func stakingState(for owner: TronAddress, now: Date = Date()) async throws -> TronStakingState {
        let identity: [String: Any] = ["address": owner.string, "visible": true]

        async let account = stakingObject("wallet/getaccount", identity)
        async let resources = stakingObject("wallet/getaccountresource", identity)
        async let reward = stakingObject("wallet/getReward", identity)
        async let withdrawable = stakingObject("wallet/getcanwithdrawunfreezeamount", [
            "owner_address": owner.string,
            "timestamp": UInt64(now.timeIntervalSince1970 * 1_000),
            "visible": true
        ])

        return try await Self.stakingState(
            account: account,
            resources: resources,
            rewards: Self.number(reward["reward"]) ?? 0,
            withdrawable: Self.number(withdrawable["amount"]) ?? 0
        )
    }
}

// MARK: - Requests

extension TronClient {
    /// The node path and JSON body that build `contract`.
    static func stakingRequest(_ contract: TronRawTransaction.Contract) throws -> (path: String, body: [String: Any]) {
        var body: [String: Any] = ["owner_address": contract.owner.string, "visible": true]

        switch contract {
        case let .freezeBalanceV2(_, amount, resource):
            body["frozen_balance"] = amount
            body["resource"] = resource.name
            return ("wallet/freezebalancev2", body)
        case let .unfreezeBalanceV2(_, amount, resource):
            body["unfreeze_balance"] = amount
            body["resource"] = resource.name
            return ("wallet/unfreezebalancev2", body)
        case .withdrawExpireUnfreeze:
            return ("wallet/withdrawexpireunfreeze", body)
        case .cancelAllUnfreezeV2:
            return ("wallet/cancelallunfreezev2", body)
        case let .voteWitness(_, votes):
            body["votes"] = votes.map { ["vote_address": $0.address.string, "vote_count": $0.count] }
            return ("wallet/votewitnessaccount", body)
        case .withdrawBalance:
            return ("wallet/withdrawbalance", body)
        case .transfer, .triggerSmartContract:
            throw WalletKitError.unsupportedFeature
        }
    }
}

// MARK: - Parsing

extension TronClient {
    static func stakingState(
        account: [String: Any],
        resources: [String: Any],
        rewards: UInt64,
        withdrawable: UInt64
    ) throws -> TronStakingState {
        // Bandwidth is the unnamed entry; `TRON_POWER` only mirrors the stake as votes.
        let frozen = (account["frozenV2"] as? [[String: Any]] ?? []).compactMap { entry in
            resource(entry["type"] as? String).map {
                TronStakingState.Frozen(amount: number(entry["amount"]) ?? 0, resource: $0)
            }
        }.filter { $0.resource != .tronPower }

        let unfrozenEntries = account["unfrozenV2"] as? [[String: Any]] ?? []
        let unfrozen = unfrozenEntries.compactMap { entry -> TronStakingState.Unfrozen? in
            guard
                let resource = resource(entry["type"] as? String),
                let expiration = number(entry["unfreeze_expire_time"])
            else {
                return nil
            }

            return TronStakingState.Unfrozen(
                amount: number(entry["unfreeze_amount"]) ?? 0,
                expiration: Date(timeIntervalSince1970: TimeInterval(expiration) / 1_000),
                resource: resource
            )
        }

        let votes = try (account["votes"] as? [[String: Any]] ?? []).compactMap { entry -> TronRawTransaction.Vote? in
            guard let address = entry["vote_address"] as? String else {
                return nil
            }

            return TronRawTransaction.Vote(
                address: try TronAddress(string: address),
                count: number(entry["vote_count"]) ?? 0
            )
        }

        // Stake delegated to others leaves `frozenV2` but still counts as voting power.
        let delegated = (number(account["delegated_frozenV2_balance_for_bandwidth"]) ?? 0)
            + (number((account["account_resource"] as? [String: Any])?["delegated_frozenV2_balance_for_energy"]) ?? 0)

        return TronStakingState(
            bandwidth: usage(resources, limit: ["freeNetLimit", "NetLimit"], used: ["freeNetUsed", "NetUsed"]),
            energy: usage(resources, limit: ["EnergyLimit"], used: ["EnergyUsed"]),
            frozen: frozen,
            rewards: rewards,
            unfrozen: unfrozen,
            votes: votes,
            weights: TronStakingState.NetworkWeights(
                energyLimit: number(resources["TotalEnergyLimit"]) ?? 0,
                energyWeight: number(resources["TotalEnergyWeight"]) ?? 0,
                netLimit: number(resources["TotalNetLimit"]) ?? 0,
                netWeight: number(resources["TotalNetWeight"]) ?? 0
            ),
            withdrawable: withdrawable,
            delegated: delegated,
            votingPower: number(resources["tronPowerLimit"])
        )
    }

    /// `ResourceCode` as TronGrid writes it: absent for `BANDWIDTH`.
    static func resource(_ name: String?) -> TronRawTransaction.Resource? {
        switch name {
        case nil, "BANDWIDTH": .bandwidth
        case "ENERGY": .energy
        case "TRON_POWER": .tronPower
        default: nil
        }
    }

    /// Sums the given limit and used fields (free and staked bandwidth).
    static func usage(_ json: [String: Any], limit: [String], used: [String]) -> TronStakingState.Usage {
        let total = limit.reduce(0) { $0 + (number(json[$1]) ?? 0) }
        let spent = used.reduce(0) { $0 + (number(json[$1]) ?? 0) }

        return TronStakingState.Usage(limit: total, remaining: total > spent ? total - spent : 0)
    }

    static let posix = Locale(identifier: "en_US_POSIX")

    static func number(_ value: Any?) -> UInt64? {
        (value as? NSNumber).map(\.uint64Value)
    }
}

// MARK: - Representatives

private extension TronClient {
    func indexedRepresentatives() async throws -> [TronRepresentative] {
        guard let tronScanEndpoint else {
            return []
        }

        let response = try await get(tronScanEndpoint.appending(path: "api/vote/witness"), apiKey: tronScanAPIKey)

        return (response["data"] as? [[String: Any]] ?? []).compactMap { witness in
            guard let address = (witness["address"] as? String).flatMap({ try? TronAddress(string: $0) }) else {
                return nil
            }

            return TronRepresentative(
                address: address,
                apr: (witness["annualizedRate"] as? String).flatMap { Decimal(string: $0, locale: Self.posix) },
                name: (witness["name"] as? String).flatMap { $0.isEmpty ? nil : $0 },
                url: (witness["url"] as? String).flatMap { $0.isEmpty ? nil : $0 },
                voteCount: Self.number(witness["realTimeVotes"]) ?? 0
            )
        }
        .sorted { $0.voteCount > $1.voteCount }
    }

    func stakingObject(_ path: String, _ body: [String: Any]) async throws -> [String: Any] {
        let data = try await relay(path: path, body: JSONSerialization.data(withJSONObject: body))
        return try JSONSerialization.jsonObject(with: data) as? [String: Any] ?? [:]
    }
}
