//
//  EthereumTransactionBuilder.swift
//  WalletKit
//
//  Created by Andrey Yurkevich on 28/08/2026.
//  Copyright © 2026 Reefr Wallet. All rights reserved.
//

import BigInt
import Foundation

// swiftlint:disable large_tuple

/// A ``BlockchainTransactionBuilderProtocol`` implementation for Ethereum,
/// backed by an ``EthereumRPCClient``.
///
/// Builds EIP-1559 transactions by default and legacy EIP-155 transactions
/// when requested in ``BlockchainTransactionBuilderOptions``. It supports
/// native ETH and ERC-20 transfers and estimates the required gas.
public struct EthereumTransactionBuilder: BlockchainTransactionBuilderProtocol {
    public typealias Address = EthereumAddress

    private let client: EthereumRPCClient

    /// Creates a builder backed by `client`.
    ///
    /// - Parameter client: The ``EthereumRPCClient`` to use for fetching
    ///   nonce, gas price, and (for ERC-20) gas limit.
    public init(client: EthereumRPCClient) {
        self.client = client
    }

    /// Builds unsigned Ethereum transaction bytes for a transfer of `amount`
    /// of `token` from `sender` to `recipient`.
    ///
    /// For native ETH transfers, fetches nonce and `eth_estimateGas` (with
    /// `from`, `to`, `value`) concurrently. For ERC-20 transfers, fetches
    /// nonce and fee rates concurrently, then calls `eth_estimateGas` with
    /// the ABI calldata.
    ///
    /// - Parameters:
    ///   - sender: The account that will sign and pay gas.
    ///   - recipient: The transfer destination (for ERC-20, the token
    ///     *recipient*, not the contract address).
    ///   - amount: Amount in wei (native ETH) or the token's smallest unit
    ///     (ERC-20).
    ///   - token: `nil` for native ETH; the ERC-20 contract address string
    ///     for a token transfer.
    ///   - options: Builder flags. Pass ``BlockchainTransactionBuilderOptions/legacyEip155``
    ///     to produce an EIP-155 legacy transaction instead of the default
    ///     EIP-1559 type-2 transaction.
    /// - Returns: Transaction signing bytes ready for
    ///   ``EthereumPKeySigner/sign(transaction:)`` or
    ///   ``EthereumTrezorSigner/sign(transaction:)``.
    /// - Throws: ``BlockchainTransactionBuilderError/invalidToken(reason:)``
    ///   if `token` isn't a valid Ethereum address;
    ///   ``BlockchainClientError`` on RPC failures.
    public func buildTransfer(
        sender: EthereumAddress,
        recipient: EthereumAddress,
        amount: BigUInt,
        token: String?,
        options: [BlockchainTransactionBuilderOptions]
    ) async throws -> Data {
        let useLegacy = options.containsLegacyEip155
        let feeOverride = options.ethereumFeeOverride

        if let tokenString = token {
            // ERC-20: rates-only estimate for fee fields; gas is estimated
            // separately with the calldata in buildERC20Transfer (unless the
            // caller has supplied a gasLimit override).
            async let nonceTask = client.nonce(of: sender)
            async let feeTask = client.estimateFee(for: nil as FeeEstimateRequest<EthereumAddress>?)
            let nonce = try await nonceTask
            let fee = try await feeTask
            return try await buildERC20Transfer(
                sender: sender,
                recipient: recipient,
                amount: amount,
                tokenString: tokenString,
                nonce: nonce,
                fee: fee,
                feeOverride: feeOverride,
                useLegacy: useLegacy
            )
        } else {
            // Native ETH: estimate gas with the actual from/to/value so that
            // contract recipients with a payable receive/fallback get the
            // right limit; fall back to 21 000 only if the node omits it.
            // Skip per-tx gas estimation when the caller has overridden gasLimit.
            async let nonceTask = client.nonce(of: sender)
            let nonce = try await nonceTask
            let fee: FeeEstimate
            if feeOverride?.gasLimit != nil {
                fee = try await client.estimateFee(for: nil as FeeEstimateRequest<EthereumAddress>?)
            } else {
                fee = try await client.estimateFee(
                    for: FeeEstimateRequest(from: sender, to: recipient, value: amount)
                )
            }
            return buildNativeTransfer(
                sender: sender,
                recipient: recipient,
                amount: amount,
                nonce: nonce,
                fee: fee,
                feeOverride: feeOverride,
                useLegacy: useLegacy
            )
        }
    }
}

// MARK: - Private helpers

private extension EthereumTransactionBuilder {
    typealias EthFeeOverride = (maxFeePerGas: BigUInt?, maxPriorityFeePerGas: BigUInt?, gasLimit: BigUInt?)

    func buildNativeTransfer(
        sender: EthereumAddress,
        recipient: EthereumAddress,
        amount: BigUInt,
        nonce: UInt64,
        fee: FeeEstimate,
        feeOverride: EthFeeOverride?,
        useLegacy: Bool
    ) -> Data {
        let gasLimit = feeOverride?.gasLimit ?? fee.gasLimit ?? 21_000
        if useLegacy {
            return UnsignedLegacyTransaction(
                nonce: BigUInt(nonce),
                gasPrice: feeOverride?.maxFeePerGas ?? fee.gasPrice,
                gasLimit: gasLimit,
                to: recipient,
                value: amount,
                data: Data(),
                chainId: client.chainId
            ).signingData
        }
        return UnsignedEIP1559Transaction(
            nonce: BigUInt(nonce),
            maxPriorityFeePerGas: feeOverride?.maxPriorityFeePerGas ?? fee.maxPriorityFeePerGas ?? fee.gasPrice,
            maxFeePerGas: feeOverride?.maxFeePerGas ?? fee.maxFeePerGas ?? fee.gasPrice,
            gasLimit: gasLimit,
            to: recipient,
            value: amount,
            data: Data(),
            chainId: client.chainId
        ).signingData
    }

    func buildERC20Transfer(
        sender: EthereumAddress,
        recipient: EthereumAddress,
        amount: BigUInt,
        tokenString: String,
        nonce: UInt64,
        fee: FeeEstimate,
        feeOverride: EthFeeOverride?,
        useLegacy: Bool
    ) async throws -> Data {
        guard let contract = try? EthereumAddress(string: tokenString) else {
            throw BlockchainTransactionBuilderError.invalidToken(
                reason: "'\(tokenString)' is not a valid Ethereum address"
            )
        }

        let calldata = EthereumABI.encodeCall(
            selector: EthereumABI.selector("transfer(address,uint256)"),
            parameters: [.address(recipient), .uint256(amount)]
        )

        // Skip per-tx gas estimation when the caller has overridden gasLimit.
        let gasLimit: BigUInt

        if let overrideGasLimit = feeOverride?.gasLimit {
            gasLimit = overrideGasLimit
        } else {
            let gasEstimate = try await client.estimateFee(
                for: FeeEstimateRequest(from: sender, to: contract, data: calldata)
            )

            // Fall back to a generous upper-bound if the node couldn't estimate.
            gasLimit = gasEstimate.gasLimit ?? 100_000
        }

        if useLegacy {
            return UnsignedLegacyTransaction(
                nonce: BigUInt(nonce),
                gasPrice: feeOverride?.maxFeePerGas ?? fee.gasPrice,
                gasLimit: gasLimit,
                to: contract,
                value: 0,
                data: calldata,
                chainId: client.chainId
            ).signingData
        } else {
            return UnsignedEIP1559Transaction(
                nonce: BigUInt(nonce),
                maxPriorityFeePerGas: feeOverride?.maxPriorityFeePerGas ?? fee.maxPriorityFeePerGas ?? fee.gasPrice,
                maxFeePerGas: feeOverride?.maxFeePerGas ?? fee.maxFeePerGas ?? fee.gasPrice,
                gasLimit: gasLimit,
                to: contract,
                value: 0,
                data: calldata,
                chainId: client.chainId
            ).signingData
        }
    }
}

private extension Array where Element == BlockchainTransactionBuilderOptions {
    /// Returns `true` when the array contains a `.legacyEip155` option.
    var containsLegacyEip155: Bool {
        contains { if case .legacyEip155 = $0 { return true }; return false }
    }

    /// Extracts the first `.ethereumFeeOverride` from the options array, or
    /// `nil` if none was supplied.
    var ethereumFeeOverride: (maxFeePerGas: BigUInt?, maxPriorityFeePerGas: BigUInt?, gasLimit: BigUInt?)? {
        for option in self {
            if case let .ethereumFeeOverride(maxFee, maxPriority, gasLimit) = option {
                return (maxFee, maxPriority, gasLimit)
            }
        }
        return nil
    }
}

// swiftlint:enable large_tuple
