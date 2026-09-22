//
//  BlockchainTransactionBuilderOptions.swift
//  WalletKit
//
//  Created by Andrey Yurkevich on 29/08/2026.
//  Copyright © 2026 Reefr Wallet. All rights reserved.
//

import BigInt
import Foundation

/// A flag passed in the `options` array of
/// ``BlockchainTransactionBuilderProtocol/buildTransfer(sender:recipient:amount:token:options:)``.
/// Pass `[]` for the chain's default behaviour; add flags to the array to
/// alter it. Flags not meaningful for a particular blockchain are ignored.
///
/// Example — force a legacy EIP-155 transaction on Ethereum:
/// ```swift
/// let txBytes = try await builder.buildTransfer(
///     sender: sender, recipient: recipient, amount: amount, token: nil,
///     options: [.legacyEip155]
/// )
/// ```
public enum BlockchainTransactionBuilderOptions: Sendable {
    /// Build a legacy EIP-155 transaction instead of the default EIP-1559
    /// (type-2) transaction. Only meaningful for Ethereum — Sui and future
    /// blockchains ignore this.
    case legacyEip155

    /// Override the EIP-1559 fee fields for an Ethereum transaction.
    ///
    /// `nil` sub-fields fall back to the value fetched from the node.
    /// Only meaningful for Ethereum (EVM) — other chains ignore this.
    case ethereumFeeOverride(maxFeePerGas: BigUInt?, maxPriorityFeePerGas: BigUInt?, gasLimit: BigUInt?)

    /// Override the gas parameters for a Sui transaction.
    ///
    /// When both `budget` and `price` are non-nil the simulate-and-select
    /// loop is skipped entirely — the supplied values are used directly.
    /// `nil` sub-fields fall back to the simulated/fetched value.
    /// Only meaningful for Sui — other chains ignore this.
    case suiGasOverride(budget: UInt64?, price: UInt64?)

    /// Override the fee rate for a Bitcoin transaction.
    ///
    /// `nil` falls back to the rate fetched from the configured backend.
    /// Only meaningful for Bitcoin — other chains ignore this.
    case bitcoinFeeOverride(feeRateSatPerVByte: UInt64?)

    /// Caps the SUN a TRC-20 smart-contract call may consume for Energy and
    /// Bandwidth. This is a spending limit, not a validator priority fee.
    case tronFeeLimit(UInt64?)

    /// Overrides the compute-unit price (the priority fee, in
    /// micro-lamports per compute unit validators are paid on top of the
    /// base fee) and/or compute-unit limit for a Solana transaction.
    ///
    /// `microLamportsPerComputeUnit` defaults to the cluster's recent
    /// median priority fee when `nil`. `computeUnitLimit` is left
    /// unset (the runtime's default per-instruction budget applies) when
    /// `nil`. Only meaningful for Solana — other chains ignore this.
    case solanaPriorityFee(microLamportsPerComputeUnit: UInt64?, computeUnitLimit: UInt32?)
}
