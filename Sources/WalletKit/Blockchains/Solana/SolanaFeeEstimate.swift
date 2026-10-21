//
//  SolanaFeeEstimate.swift
//  WalletKit
//
//  Created by Andrey Yurkevich on 06/10/2026.
//  Copyright © 2026 Reefr Wallet. All rights reserved.
//

/// ``SolanaRPCClient/estimateFee(transaction:)``'s result.
public struct SolanaFeeEstimate: Sendable, Equatable {
    /// The message's `SetComputeUnitLimit`, if set.
    public let computeUnitLimit: UInt32?

    /// The message's `SetComputeUnitPrice`, in µLamports per compute
    /// unit; 0 if unset.
    public let computeUnitPrice: UInt64

    /// Total fee in lamports: base fee plus priority fee.
    public let fee: UInt64

    public init(computeUnitLimit: UInt32?, computeUnitPrice: UInt64, fee: UInt64) {
        self.computeUnitLimit = computeUnitLimit
        self.computeUnitPrice = computeUnitPrice
        self.fee = fee
    }
}
