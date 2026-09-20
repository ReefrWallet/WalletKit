//
//  FeeEstimate.swift
//  WalletKit
//
//  Created by Andrey Yurkevich on 27/08/2026.
//  Copyright © 2026 Reefr Wallet. All rights reserved.
//

import BigInt

/// Current network fee rates and an optional per-transaction gas estimate for
/// one blockchain client.
///
/// **Ethereum (EIP-1559):** ``gasPrice`` is `eth_gasPrice` in wei per gas
/// unit; ``maxFeePerGas`` is `baseFee × 2 + maxPriorityFeePerGas` (the
/// worst-case upper bound on what you pay per gas unit); and
/// ``maxPriorityFeePerGas`` is the validator tip. When a
/// ``FeeEstimateRequest`` is supplied, ``gasLimit`` is the node's
/// `eth_estimateGas` estimate and ``estimatedFee`` is
/// `gasLimit × maxFeePerGas` (in wei). Use ``maxFeePerGas`` to build an
/// EIP-1559 transaction — it guarantees inclusion if the base fee is ≤ the
/// observed value at the time of estimation, which is true for the next few
/// blocks.
///
/// **Sui:** Only ``gasPrice`` is populated (the epoch's
/// `reference_gas_price`, in MIST per gas unit); ``maxFeePerGas`` and
/// ``maxPriorityFeePerGas`` are `nil` — Sui has no EIP-1559 fee model.
/// When a ``FeeEstimateRequest`` is supplied, ``estimatedFee`` is
/// `computation_cost + storage_cost − storage_rebate` from the simulated
/// transaction's gas summary (floored at 0), and ``gasLimit`` is
/// `computation_cost / gasPrice` (nil if `gasPrice` is 0).
/// ``grossFee`` is `computation_cost + storage_cost` (before rebate) — use
/// this as the basis for the gas budget, since the rebate is only credited
/// after execution and the budget must cover the full gross cost.
public struct FeeEstimate: Sendable, Equatable {
    /// Current network gas price.
    ///
    /// - **Ethereum**: `eth_gasPrice`, in wei per gas unit. Use as the
    ///   `gasPrice` field in a legacy transaction, or as a lower bound for
    ///   setting `maxFeePerGas` in an EIP-1559 transaction (which
    ///   ``maxFeePerGas`` already accounts for via the base-fee factor).
    /// - **Sui**: the epoch's `reference_gas_price`, in MIST per gas unit.
    public let gasPrice: BigUInt

    /// EIP-1559 maximum fee per gas (`baseFee × 2 + maxPriorityFeePerGas`).
    /// `nil` on Sui, which has no EIP-1559 fee model.
    ///
    /// Setting `maxFeePerGas` to this value in a transaction provides a
    /// 2× headroom over the observed base fee, enough to absorb several
    /// consecutive full blocks without repricing.
    public let maxFeePerGas: BigUInt?

    /// EIP-1559 validator tip (`eth_maxPriorityFeePerGas`), in wei per gas
    /// unit. `nil` on Sui.
    public let maxPriorityFeePerGas: BigUInt?

    /// Estimated gas units the transaction will consume. `nil` when no
    /// ``FeeEstimateRequest`` was supplied (rates-only mode).
    ///
    /// - **Ethereum**: result of `eth_estimateGas`.
    /// - **Sui**: `computation_cost ÷ gasPrice`, or `nil` if `gasPrice`
    ///   is 0.
    public let gasLimit: BigUInt?

    /// Total estimated transaction fee, in the chain's smallest unit. `nil`
    /// when no ``FeeEstimateRequest`` was supplied (rates-only mode).
    ///
    /// - **Ethereum**: `gasLimit × maxFeePerGas`, in wei — the maximum
    ///   amount the transaction can spend on gas.
    /// - **Sui**: `computation_cost + storage_cost − storage_rebate`, in
    ///   MIST, floored at 0.
    public let estimatedFee: BigUInt?

    /// Gross transaction cost before storage rebate, in MIST. Sui only —
    /// `nil` on Ethereum and in rates-only mode.
    ///
    /// Equal to `computation_cost + storage_cost`. Use this (not
    /// ``estimatedFee``) to derive the gas budget: the rebate is credited
    /// after execution, so the budget must cover the full gross cost.
    public let grossFee: BigUInt?

    /// Creates a fee estimate.
    ///
    /// - Parameters:
    ///   - gasPrice: Current network gas price (in wei on Ethereum, MIST on
    ///     Sui).
    ///   - maxFeePerGas: EIP-1559 max fee per gas. `nil` on Sui.
    ///   - maxPriorityFeePerGas: EIP-1559 validator tip. `nil` on Sui.
    ///   - gasLimit: Estimated gas units. `nil` for rates-only mode.
    ///   - estimatedFee: Total estimated fee. `nil` for rates-only mode.
    ///   - grossFee: Gross cost before storage rebate (Sui only). `nil` on
    ///     Ethereum and in rates-only mode.
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
