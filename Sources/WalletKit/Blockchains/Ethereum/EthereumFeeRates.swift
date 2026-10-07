//
//  EthereumFeeRates.swift
//  WalletKit
//
//  Created by Andrey Yurkevich on 06/10/2026.
//  Copyright © 2026 Reefr Wallet. All rights reserved.
//

import BigInt

/// Current EVM fee rates, in wei per gas — ``EthereumRPCClient/feeRates()``.
public struct EthereumFeeRates: Sendable, Equatable {
    /// Legacy `eth_gasPrice`.
    public let gasPrice: BigUInt

    /// EIP-1559 max fee per gas: `baseFee × 2 + maxPriorityFeePerGas`.
    public let maxFeePerGas: BigUInt

    /// EIP-1559 validator tip.
    public let maxPriorityFeePerGas: BigUInt

    public init(gasPrice: BigUInt, maxFeePerGas: BigUInt, maxPriorityFeePerGas: BigUInt) {
        self.gasPrice = gasPrice
        self.maxFeePerGas = maxFeePerGas
        self.maxPriorityFeePerGas = maxPriorityFeePerGas
    }
}
