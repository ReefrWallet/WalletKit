//
//  FeeEstimateRequest.swift
//  WalletKit
//
//  Created by Andrey Yurkevich on 27/08/2026.
//  Copyright © 2026 Reefr Wallet. All rights reserved.
//

import BigInt
import Foundation

/// Describes the transaction to estimate fees for, typed to a specific
/// blockchain's address type.
///
/// Populate the fields required by the target chain. Pass `nil` to
/// ``BlockchainClientProtocol/estimateFee(for:)`` for a rates-only estimate.
public struct FeeEstimateRequest<Address: BlockchainAddress>: Sendable {
    /// The sender address, when required by the chain.
    public let from: Address?

    /// The destination address, when required by the chain.
    public let to: Address?

    /// The native-token value to simulate, in the chain's smallest unit.
    public let value: BigUInt?

    /// Chain-specific transaction data.
    public let data: Data?

    /// Creates a fee estimate request.
    ///
    /// - Parameters:
    ///   - from: The sender address.
    ///   - to: The destination address.
    ///   - value: The native-token value to simulate.
    ///   - data: Chain-specific transaction data.
    public init(
        from: Address? = nil,
        to: Address? = nil,
        value: BigUInt? = nil,
        data: Data? = nil
    ) {
        self.from = from
        self.to = to
        self.value = value
        self.data = data
    }
}

/// String-addressed version of ``FeeEstimateRequest``, accepted by
/// ``AnyBlockchainClient/estimateFee(for:)``. ``AnyBlockchainClient`` bridges
/// each `String` address to the concrete chain's `Address` type via
/// `Address(string:)` before forwarding to the underlying typed client.
///
/// Construct one of these whenever you hold an ``AnyBlockchainClient`` and
/// want a per-transaction fee estimate. Pass `nil` to
/// ``AnyBlockchainClient/estimateFee(for:)`` for a rates-only estimate.
public struct AnyFeeEstimateRequest: Sendable {
    /// The sender's address string.
    public let from: String?

    /// The destination address string.
    public let to: String?

    /// The native-token value to simulate.
    public let value: BigUInt?

    /// Chain-specific transaction data.
    public let data: Data?

    /// Creates a string-addressed fee estimate request.
    ///
    /// - Parameters:
    ///   - from: The sender's address string.
    ///   - to: The destination address string.
    ///   - value: The native-token value to simulate.
    ///   - data: Chain-specific transaction data.
    public init(
        from: String? = nil,
        to: String? = nil,
        value: BigUInt? = nil,
        data: Data? = nil
    ) {
        self.from = from
        self.to = to
        self.value = value
        self.data = data
    }
}
