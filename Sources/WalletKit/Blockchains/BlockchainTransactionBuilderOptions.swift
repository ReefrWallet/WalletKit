//
//  BlockchainTransactionBuilderOptions.swift
//  WalletKit
//
//  Created by Andrey Yurkevich on 29/08/2026.
//  Copyright © 2026 Reefr Wallet. All rights reserved.
//

import BigInt
import Foundation

/// An option passed to
/// ``BlockchainTransactionBuilderProtocol/buildTransfer(sender:recipient:amount:token:options:)``.
/// Use an empty array for default behavior. Builders ignore unsupported
/// options.
public enum BlockchainTransactionBuilderOptions: Sendable {
    /// Override the gas parameters for an Aptos transaction.
    ///
    /// `nil` sub-fields fall back to simulated or fetched values.
    case aptosGasOverride(maxGasAmount: UInt64?, gasUnitPrice: UInt64?)

    /// Build a legacy EIP-155 transaction instead of the default EIP-1559
    /// (type-2) transaction.
    case legacyEip155

    /// Override the EIP-1559 fee fields for an Ethereum transaction.
    ///
    /// `nil` sub-fields fall back to the value fetched from the node.
    case ethereumFeeOverride(maxFeePerGas: BigUInt?, maxPriorityFeePerGas: BigUInt?, gasLimit: BigUInt?)

    /// Override the gas parameters for a Sui transaction.
    ///
    /// `nil` sub-fields fall back to simulated or fetched values.
    case suiGasOverride(budget: UInt64?, price: UInt64?)

    /// Override the fee rate for a Bitcoin transaction.
    ///
    /// `nil` falls back to the rate fetched from the configured backend.
    case bitcoinFeeOverride(feeRateSatPerVByte: UInt64?)

    /// Sets the lovelace carried by a Cardano native-asset recipient output.
    /// ADA transfers ignore this value; token outputs must satisfy the ledger's
    /// minimum-ADA requirement.
    case cardanoRecipientLovelace(UInt64?)

    /// Caps the SUN a TRC-20 smart-contract call may consume for Energy and
    /// Bandwidth. This is a spending limit, not a validator priority fee.
    case tronFeeLimit(UInt64?)

    /// Overrides the compute-unit price (the priority fee, in
    /// µLamports per compute unit validators are paid on top of the
    /// base fee) and/or compute-unit limit for a Solana transaction.
    ///
    /// `microLamportsPerComputeUnit` defaults to the cluster's recent
    /// median priority fee when `nil`. `computeUnitLimit` is left
    /// unset (the runtime's default per-instruction budget applies) when
    /// `nil`. Only meaningful for Solana — other chains ignore this.
    case solanaPriorityFee(microLamportsPerComputeUnit: UInt64?, computeUnitLimit: UInt32?)
}
