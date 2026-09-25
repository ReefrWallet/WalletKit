//
//  AnyBlockchainClient.swift
//  WalletKit
//
//  Created by Andrey Yurkevich on 27/08/2026.
//  Copyright © 2026 Reefr Wallet. All rights reserved.
//

import BigInt
import Foundation

/// A type-erased, String-addressed wrapper around any
/// ``BlockchainClientProtocol`` conformer.
///
/// Use this type when the concrete address type is not known statically.
public struct AnyBlockchainClient: Sendable {
    // MARK: - Stored closures (one per protocol requirement)

    private let _getAllBalances: @Sendable (String) async throws -> [String: BigUInt]
    private let _getBalances: @Sendable (String, [String]) async throws -> [String: BigUInt]
    private let _getBalance: @Sendable (String, String) async throws -> BigUInt
    private let _getNativeBalance: @Sendable (String) async throws -> BigUInt
    private let _getTokenInfo: @Sendable (String?) async throws -> TokenInfo
    private let _getTokenPrice: @Sendable (String?) async throws -> Decimal
    private let _isActiveAccount: @Sendable (String) async throws -> Bool
    private let _isSupported: @Sendable (BlockchainClientFeature) -> Bool
    private let _estimateFee: @Sendable (AnyFeeEstimateRequest?) async throws -> FeeEstimate
    private let _broadcast: @Sendable (Data, Data) async throws -> String
    private let _transactionHeads: @Sendable (
        String
    ) -> AsyncThrowingStream<BlockchainTransactionHead, any Swift.Error>
    private let _transactionHistory: @Sendable (
        String,
        BlockchainTransactionHistoryRequest
    ) async throws -> BlockchainTransactionPage

    // MARK: - Initialiser

    /// Wraps `client`, erasing its concrete `Address` type behind String-based
    /// forwarding closures.
    ///
    /// - Parameters:
    ///   - client: The client to wrap.
    ///   - makeAddress: Creates the client's address type from a string.
    public init<C: BlockchainClientProtocol>( // swiftlint:disable:this function_body_length
        _ client: C,
        makeAddress: @Sendable @escaping (String) throws -> C.Address = { try C.Address(string: $0) }
    ) {
        _getAllBalances = { ownerString in
            let owner = try makeAddress(ownerString)
            return try await client.getAllBalances(owner)
        }
        _getBalances = { ownerString, tokens in
            let owner = try makeAddress(ownerString)
            return try await client.getBalances(owner, tokens: tokens)
        }
        _getBalance = { ownerString, token in
            let owner = try makeAddress(ownerString)
            return try await client.getBalance(owner, token: token)
        }
        _getNativeBalance = { ownerString in
            let owner = try makeAddress(ownerString)
            return try await client.getNativeBalance(owner)
        }
        _getTokenInfo = { token in
            try await client.getTokenInfo(token)
        }
        _getTokenPrice = { token in
            try await client.getTokenPrice(token)
        }
        _isActiveAccount = { ownerString in
            let owner = try makeAddress(ownerString)
            return try await client.isActiveAccount(owner)
        }
        _isSupported = { feature in
            client.isSupported(feature)
        }
        _estimateFee = { anyRequest in
            guard let anyRequest else {
                return try await client.estimateFee(for: nil)
            }
            // Bridge String addresses → C.Address, forwarding nil as nil.
            let typedFrom = try anyRequest.from.map { try makeAddress($0) }
            let typedTo = try anyRequest.to.map { try makeAddress($0) }
            let typedRequest = FeeEstimateRequest<C.Address>(
                from: typedFrom,
                to: typedTo,
                value: anyRequest.value,
                data: anyRequest.data
            )
            return try await client.estimateFee(for: typedRequest)
        }
        _broadcast = { transaction, signature in
            try await client.broadcast(transaction: transaction, signature: signature)
        }
        _transactionHistory = { ownerString, request in
            let owner = try makeAddress(ownerString)
            return try await client.transactionHistory(owner, request: request)
        }
        _transactionHeads = { ownerString in
            guard let owner = try? makeAddress(ownerString) else {
                return AsyncThrowingStream { continuation in
                    continuation.finish(throwing: WalletKitError.invalidAddress(reason: "Invalid account address"))
                }
            }
            return client.transactionHeads(owner)
        }
    }

    // MARK: - Forwarding methods

    /// Returns all token balances for `owner`. Throws
    /// ``WalletKitError/unsupportedFeature`` on chains that don't support
    /// bulk balance queries (check ``isSupported(_:)`` with
    /// ``BlockchainClientFeature/allBalances`` first).
    ///
    /// - Parameter owner: The account's address string.
    /// - Returns: A dictionary keyed by token contract address / coin type,
    ///   mapping to raw balance in the token's smallest unit.
    public func getAllBalances(_ owner: String) async throws -> [String: BigUInt] {
        try await _getAllBalances(owner)
    }

    /// Returns balances for the requested token identifiers.
    public func getBalances(_ owner: String, tokens: [String]) async throws -> [String: BigUInt] {
        try await _getBalances(owner, tokens)
    }

    /// Returns `owner`'s balance of the ERC-20/coin at `token`.
    ///
    /// - Parameters:
    ///   - owner: The account's address string.
    ///   - token: The ERC-20 contract address or Sui coin-type string.
    public func getBalance(_ owner: String, token: String) async throws -> BigUInt {
        try await _getBalance(owner, token)
    }

    /// Returns `owner`'s native-token balance (ETH in wei, SUI in MIST).
    ///
    /// - Parameter owner: The account's address string.
    public func getNativeBalance(_ owner: String) async throws -> BigUInt {
        try await _getNativeBalance(owner)
    }

    /// Returns metadata for `token` — name, symbol, decimals.
    ///
    /// - Parameter token: The token contract address or coin-type string. Pass
    ///   `nil` for the chain's native token.
    public func getTokenInfo(_ token: String?) async throws -> TokenInfo {
        try await _getTokenInfo(token)
    }

    /// Returns the current USD price of `token`.
    ///
    /// - Parameter token: The token contract address or coin-type string. Pass
    ///   `nil` for the chain's native token.
    public func getTokenPrice(_ token: String?) async throws -> Decimal {
        try await _getTokenPrice(token)
    }

    /// Returns whether `owner` has been active on this chain — e.g. has a
    /// non-zero balance or has sent at least one transaction.
    ///
    /// - Parameter owner: The account's address string.
    public func isActiveAccount(_ owner: String) async throws -> Bool {
        try await _isActiveAccount(owner)
    }

    /// Returns whether the underlying client supports `feature`.
    public func isSupported(_ feature: BlockchainClientFeature) -> Bool {
        _isSupported(feature)
    }

    /// Returns current network fee rates and, when `request` is non-nil, a
    /// per-transaction gas estimate.
    ///
    /// Pass `nil` to get only the current network rates (no per-tx estimate).
    /// See ``FeeEstimate`` for chain-specific field semantics.
    ///
    /// - Parameter request: An optional ``AnyFeeEstimateRequest`` describing
    ///   the transaction to estimate fees for. `nil` returns rates-only.
    /// - Returns: A ``FeeEstimate`` with the current gas rates and, when
    ///   `request` is non-nil, ``FeeEstimate/gasLimit`` and
    ///   ``FeeEstimate/estimatedFee``.
    /// - Throws: An invalid-address error if a supplied address string is
    ///   malformed; ``BlockchainClientError`` on a transport, RPC, or
    ///   decoding failure.
    public func estimateFee(for request: AnyFeeEstimateRequest?) async throws -> FeeEstimate {
        try await _estimateFee(request)
    }

    /// Broadcasts a signed transaction and returns its identifier.
    ///
    /// - Parameters:
    ///   - transaction: The unsigned transaction bytes, when required by the
    ///     chain.
    ///   - signature: The signed transaction data.
    /// - Returns: The transaction identifier.
    /// - Throws: ``BlockchainClientError`` on a transport or RPC failure.
    public func broadcast(transaction: Data, signature: Data) async throws -> String {
        try await _broadcast(transaction, signature)
    }

    /// Returns one bounded page of normalised account activity.
    public func transactionHistory(
        _ owner: String,
        request: BlockchainTransactionHistoryRequest
    ) async throws -> BlockchainTransactionPage {
        try await _transactionHistory(owner, request)
    }

    public func transactionHeads(_ owner: String) -> AsyncThrowingStream<BlockchainTransactionHead, any Swift.Error> {
        _transactionHeads(owner)
    }
}
