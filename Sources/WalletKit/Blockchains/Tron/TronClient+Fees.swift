//
//  TronClient+Fees.swift
//  WalletKit
//
//  Created by Andrey Yurkevich on 14/10/2026.
//  Copyright © 2026 Reefr Wallet. All rights reserved.
//

import Foundation

/// What a Tron transaction is expected to cost its owner. Tron charges
/// energy (contract execution) and bandwidth (transaction bytes); whatever
/// the account's staked/free resources don't cover is burned as TRX.
/// A transaction's `fee_limit` only caps the energy burn.
public struct TronFeeEstimate: Equatable, Sendable {
    /// Energy the call is expected to use (0 for plain transfers).
    public let energy: UInt64
    /// Signed transaction size in bytes, as bandwidth is charged.
    public let bandwidth: UInt64
    /// TRX (in SUN) burned for the bandwidth the account's resources don't cover.
    public let bandwidthBurnSun: UInt64
    /// TRX (in SUN) burned for the energy the account's resources don't cover.
    public let energyBurnSun: UInt64
    /// Energy the account has left today (staked), which pays for `energy` first.
    public let availableEnergy: UInt64
    /// Bandwidth the account has left today in the pool that can pay: the staked or the free
    /// allowance, whichever is larger. The pools don't add up; one must cover the whole transaction.
    public let availableBandwidth: UInt64
    /// The account's daily allowances as read for this estimate, when it read them.
    public let resources: TronResourceUsage?

    public init(
        energy: UInt64,
        bandwidth: UInt64,
        bandwidthBurnSun: UInt64 = 0,
        energyBurnSun: UInt64 = 0,
        availableEnergy: UInt64 = 0,
        availableBandwidth: UInt64 = 0,
        resources: TronResourceUsage? = nil
    ) {
        self.energy = energy
        self.bandwidth = bandwidth
        self.bandwidthBurnSun = bandwidthBurnSun
        self.energyBurnSun = energyBurnSun
        self.availableEnergy = availableEnergy
        self.availableBandwidth = availableBandwidth
        self.resources = resources
    }

    /// TRX (in SUN) expected to be burned after the account's resources.
    public var burnedSun: UInt64 {
        bandwidthBurnSun + energyBurnSun
    }

    /// Whether the account's own resources pay for the whole transaction.
    public var isCoveredByResources: Bool {
        burnedSun == 0
    }

    /// Whether the account has enough energy left for the call.
    public var isEnergyCovered: Bool {
        energy <= availableEnergy
    }

    /// Whether the account has enough bandwidth left for the transaction.
    public var isBandwidthCovered: Bool {
        bandwidth <= availableBandwidth
    }
}

public extension TronClient {
    /// Estimates `transaction`'s cost for its owner: energy from a
    /// `triggerconstantcontract` dry run, the owner's available energy and
    /// bandwidth from `getaccountresource`, and prices from
    /// `getchainparameters`. Approximate — energy can differ at execution.
    func estimateFee(for transaction: TronRawTransaction) async throws -> TronFeeEstimate {
        let owner = transaction.contract.owner

        async let energy = estimatedEnergy(for: transaction.contract)
        async let resources = post("wallet/getaccountresource", body: ["address": owner.rawBytes.bareHex])
        async let parameters = post("wallet/getchainparameters", body: [:])

        let (energyUsed, resourcesJSON, parametersJSON) = try await (energy, resources, parameters)
        let prices = Self.chainParameters(parametersJSON)

        // Signed transaction: raw data + 65-byte signature + protobuf
        // framing, plus the 64 bytes java-tron adds for the result.
        let bandwidth = UInt64(transaction.rawBytes.count) + 65 + 6 + 64

        let availableEnergy = Self.difference(resourcesJSON, "EnergyLimit", "EnergyUsed")
        // Staked and free bandwidth are separate pools: one of them must cover the whole
        // transaction, otherwise the node burns TRX for all of it.
        let availableBandwidth = max(
            Self.difference(resourcesJSON, "freeNetLimit", "freeNetUsed"),
            Self.difference(resourcesJSON, "NetLimit", "NetUsed")
        )

        let energyBurn = energyUsed > availableEnergy ? (energyUsed - availableEnergy) * prices.energyFee : 0
        let bandwidthBurn = bandwidth > availableBandwidth ? bandwidth * prices.transactionFee : 0

        return TronFeeEstimate(
            energy: energyUsed,
            bandwidth: bandwidth,
            bandwidthBurnSun: bandwidthBurn,
            energyBurnSun: energyBurn,
            availableEnergy: availableEnergy,
            availableBandwidth: availableBandwidth,
            resources: Self.resourceUsage(resourcesJSON)
        )
    }
}

private extension TronClient {
    func estimatedEnergy(for contract: TronRawTransaction.Contract) async throws -> UInt64 {
        guard case let .triggerSmartContract(owner, address, callValue, data) = contract else {
            return 0
        }

        let response = try await post("wallet/triggerconstantcontract", body: [
            "call_value": callValue,
            "contract_address": address.rawBytes.bareHex,
            "data": data.bareHex,
            "owner_address": owner.rawBytes.bareHex
        ])

        guard let used = Self.uint64(response["energy_used"]) else {
            throw WalletKitError.internalError(message: "Tron node did not estimate energy.")
        }

        // Already includes any dynamic-energy `energy_penalty`.
        return used
    }

    /// Energy and bandwidth prices in SUN, defaulting to the current
    /// mainnet values if the node omits them.
    static func chainParameters(_ json: [String: Any]) -> (energyFee: UInt64, transactionFee: UInt64) {
        let parameters = json["chainParameter"] as? [[String: Any]] ?? []
        func value(_ key: String, default fallback: UInt64) -> UInt64 {
            parameters.first { $0["key"] as? String == key }.flatMap { uint64($0["value"]) } ?? fallback
        }

        return (value("getEnergyFee", default: 100), value("getTransactionFee", default: 1_000))
    }

    static func difference(_ json: [String: Any], _ limit: String, _ used: String) -> UInt64 {
        let limit = uint64(json[limit]) ?? 0
        let used = uint64(json[used]) ?? 0
        return limit > used ? limit - used : 0
    }
}
