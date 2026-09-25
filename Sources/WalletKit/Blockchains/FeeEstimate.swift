//
//  FeeEstimate.swift
//  WalletKit
//
//  Created by Andrey Yurkevich on 27/08/2026.
//  Copyright © 2026 Reefr Wallet. All rights reserved.
//

import BigInt

/// Current fee information for one blockchain client.
///
/// Available fields and units depend on the chain. A `nil` value is either
/// unsupported or unavailable in rates-only mode.
public struct FeeEstimate: Sendable, Equatable {
    /// Current network fee-unit price.
    public let gasPrice: BigUInt

    /// EIP-1559 maximum fee per gas, when supported.
    public let maxFeePerGas: BigUInt?

    /// EIP-1559 validator tip, when supported.
    public let maxPriorityFeePerGas: BigUInt?

    /// Estimated fee units the transaction will consume.
    public let gasLimit: BigUInt?

    /// Total estimated transaction fee in the chain's smallest unit.
    public let estimatedFee: BigUInt?

    /// Gross transaction cost before storage rebate, when supplied by the
    /// chain.
    public let grossFee: BigUInt?

    /// Creates a fee estimate.
    ///
    /// - Parameters:
    ///   - gasPrice: Current network fee-unit price.
    ///   - maxFeePerGas: EIP-1559 maximum fee per gas, when supported.
    ///   - maxPriorityFeePerGas: EIP-1559 validator tip, when supported.
    ///   - gasLimit: Estimated fee units, when available.
    ///   - estimatedFee: Total estimated fee, when available.
    ///   - grossFee: Gross cost before storage rebate, when available.
    public init(
        gasPrice: BigUInt,
        maxFeePerGas: BigUInt? = nil,
        maxPriorityFeePerGas: BigUInt? = nil,
        gasLimit: BigUInt? = nil,
        estimatedFee: BigUInt? = nil,
        grossFee: BigUInt? = nil
    ) {
        self.gasPrice = gasPrice
        self.maxFeePerGas = maxFeePerGas
        self.maxPriorityFeePerGas = maxPriorityFeePerGas
        self.gasLimit = gasLimit
        self.estimatedFee = estimatedFee
        self.grossFee = grossFee
    }
}
