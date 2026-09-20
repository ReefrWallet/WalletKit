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
/// All fields are optional — populate only the ones the target chain uses:
///
/// - **Ethereum (EIP-1559):** supply at minimum ``to`` (the call/transfer
///   destination). Populate ``value`` for a native-ETH transfer and ``data``
///   for a contract call (ABI calldata). The ``to`` field is also what gates
///   the per-tx path: if it is `nil`,
///   ``BlockchainClientProtocol/estimateFee(for:)`` returns rates-only (no
///   ``FeeEstimate/gasLimit`` or ``FeeEstimate/estimatedFee``).
///
/// - **Sui:** supply ``data`` with unsigned BCS-encoded `TransactionData`
///   bytes (e.g. from `UnsignedSuiTransaction.transactionDataBcs`). If `nil`,
///   ``BlockchainClientProtocol/estimateFee(for:)`` returns rates-only. The
///   ``from``, ``to``, and ``value`` fields are ignored.
///
/// Pass `nil` to ``BlockchainClientProtocol/estimateFee(for:)`` to fetch
/// only the current network rates without any per-transaction estimate.
public struct FeeEstimateRequest<Address: BlockchainAddress>: Sendable {
    /// The sender — used as `from` in `eth_estimateGas`. `nil` asks the node
    /// to use a default sender (which most nodes accept). Ignored on Sui.
    public let from: Address?

    /// The destination address. Required to trigger a per-tx estimate on
    /// Ethereum; if `nil`, ``BlockchainClientProtocol/estimateFee(for:)``
    /// returns rates-only. Ignored on Sui.
    public let to: Address?

    /// The ETH value to simulate sending, in wei. `nil` defaults to 0 wei.
    /// Ignored on Sui.
    public let value: BigUInt?

    /// Chain-specific transaction data:
    ///
    /// - **Ethereum:** ABI-encoded calldata for a contract call. `nil` means
    ///   a plain ETH transfer (`eth_estimateGas` returns 21 000 gas for a
    ///   pure ETH send with no calldata).
    /// - **Sui:** unsigned BCS-encoded `TransactionData` bytes (e.g.
    ///   `UnsignedSuiTransaction.transactionDataBcs`), passed directly to
    ///   `TransactionExecutionService.simulateTransaction`. `nil` produces a
    ///   rates-only estimate (``FeeEstimate/estimatedFee`` and
    ///   ``FeeEstimate/gasLimit`` will both be `nil`).
    public let data: Data?

    /// Creates a fee estimate request.
    ///
    /// - Parameters:
    ///   - from: The sender. `nil` (default) lets the node pick a default.
    ///     Ethereum only.
    ///   - to: The destination. Required for a per-tx Ethereum estimate.
    ///     Ignored on Sui.
    ///   - value: ETH value in wei. `nil` (default) = 0. Ethereum only.
    ///   - data: ABI calldata (Ethereum) or unsigned BCS `TransactionData`
    ///     bytes (Sui). `nil` (default) = rates-only on Sui, plain ETH
    ///     transfer on Ethereum.
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
    /// The sender's address string, or `nil` for a node-default sender.
    /// Ethereum only.
    public let from: String?

    /// The destination address string. Required for a per-tx Ethereum
    /// estimate; `nil` returns rates-only. Ignored on Sui.
    public let to: String?

    /// ETH value in wei. `nil` = 0. Ethereum only.
    public let value: BigUInt?

    /// ABI calldata (Ethereum) or unsigned BCS `TransactionData` bytes (Sui).
    /// `nil` = rates-only on Sui, plain ETH transfer on Ethereum.
    public let data: Data?

    /// Creates a string-addressed fee estimate request.
    ///
    /// - Parameters:
    ///   - from: The sender's address string. `nil` (default) = node default.
    ///     Ethereum only.
    ///   - to: The destination. Required for a per-tx Ethereum estimate.
    ///     Ignored on Sui.
    ///   - value: ETH value in wei. `nil` (default) = 0. Ethereum only.
    ///   - data: ABI calldata (Ethereum) or unsigned BCS `TransactionData`
    ///     bytes (Sui). `nil` (default) = rates-only.
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
