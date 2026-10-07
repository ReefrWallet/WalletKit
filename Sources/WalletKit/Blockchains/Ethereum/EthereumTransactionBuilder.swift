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
    /// Native ETH is a plain value call to `recipient`; ERC-20 is a
    /// `transfer(address,uint256)` call to the token contract. Both go
    /// through ``buildCall(sender:to:value:data:options:)``.
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
        let to: EthereumAddress
        let value: BigUInt
        let data: Data

        if let token {
            guard let contract = try? EthereumAddress(string: token) else {
                throw BlockchainTransactionBuilderError.invalidToken(
                    reason: "'\(token)' is not a valid Ethereum address"
                )
            }

            to = contract
            value = 0
            data = EthereumABI.encodeCall(
                selector: EthereumABI.selector("transfer(address,uint256)"),
                parameters: [.address(recipient), .uint256(amount)]
            )
        } else {
            to = recipient
            value = amount
            data = Data()
        }

        return try await buildCall(sender: sender, to: to, value: value, data: data, options: options)
    }

    /// Builds unsigned Ethereum transaction bytes for an arbitrary call —
    /// `to` optional so contract deployment (`to == nil`) works, `data`
    /// caller-supplied — the entry point a dapp's `eth_sendTransaction`
    /// needs. Fetches nonce, ``EthereumRPCClient/feeRates()`` and
    /// ``EthereumRPCClient/estimateGas(from:to:value:data:)`` concurrently.
    ///
    /// - Parameters:
    ///   - sender: The account that will sign and pay gas.
    ///   - to: The call destination, or `nil` for contract creation.
    ///   - value: Native ETH value in wei.
    ///   - data: The call data (ABI-encoded function call, or contract
    ///     creation bytecode).
    ///   - options: Builder flags — ``BlockchainTransactionBuilderOptions/legacyEip155``
    ///     for an EIP-155 legacy transaction, or
    ///     ``BlockchainTransactionBuilderOptions/ethereumFeeOverride(maxFeePerGas:maxPriorityFeePerGas:gasLimit:)``
    ///     to take a dapp's own gas fields over the node's estimate.
    /// - Returns: Transaction signing bytes ready for
    ///   ``EthereumPKeySigner/sign(transaction:)`` or
    ///   ``EthereumTrezorSigner/sign(transaction:)``.
    /// - Throws: ``BlockchainClientError`` on RPC failures.
    public func buildCall(
        sender: EthereumAddress,
        to: EthereumAddress?,
        value: BigUInt,
        data: Data,
        options: [BlockchainTransactionBuilderOptions]
    ) async throws -> Data {
        let feeOverride = options.ethereumFeeOverride

        async let nonceTask = client.nonce(of: sender)
        async let ratesTask = client.feeRates()

        // Skip `eth_estimateGas` when the caller has overridden gasLimit.
        let gasLimit: BigUInt
        if let overrideGasLimit = feeOverride?.gasLimit {
            gasLimit = overrideGasLimit
        } else {
            gasLimit = try await client.estimateGas(from: sender, to: to, value: value, data: data)
        }

        let nonce = BigUInt(try await nonceTask)
        let rates = try await ratesTask

        if options.containsLegacyEip155 {
            return UnsignedLegacyTransaction(
                nonce: nonce,
                gasPrice: feeOverride?.maxFeePerGas ?? rates.gasPrice,
                gasLimit: gasLimit,
                to: to,
                value: value,
                data: data,
                chainId: client.chainId
            ).signingData
        }

        return UnsignedEIP1559Transaction(
            nonce: nonce,
            maxPriorityFeePerGas: feeOverride?.maxPriorityFeePerGas ?? rates.maxPriorityFeePerGas,
            maxFeePerGas: feeOverride?.maxFeePerGas ?? rates.maxFeePerGas,
            gasLimit: gasLimit,
            to: to,
            value: value,
            data: data,
            chainId: client.chainId
        ).signingData
    }
}

private extension Array where Element == BlockchainTransactionBuilderOptions {
    /// Returns `true` when the array contains a `.legacyEip155` option.
    var containsLegacyEip155: Bool {
        contains { if case .legacyEip155 = $0 {
            return true
        }; return false }
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
