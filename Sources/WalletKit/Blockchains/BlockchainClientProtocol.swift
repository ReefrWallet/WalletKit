//
//  BlockchainClientProtocol.swift
//  Reefr Wallet
//
//  Created by Andrey Yurkevich on 18.02.26.
//  Copyright © 2026 Reefr Wallet. All rights reserved.
//

@_documentation(visibility: internal) @_exported import Foundation
@_documentation(visibility: internal) @_exported import BigInt

/// Discrete capabilities a ``BlockchainClientProtocol`` conformer may or may
/// not support. Call ``BlockchainClientProtocol/isSupported(_:)`` before
/// using a feature to avoid ``WalletKitError/unsupportedFeature`` errors at
/// runtime.
public enum BlockchainClientFeature {
    /// Bulk balance query for a requested set of token/coin identifiers.
    case multipleBalances

    /// Bulk balance query — ``BlockchainClientProtocol/getAllBalances(_:)``
    /// returns balances for every token or coin the account holds in one call.
    case allBalances

    /// Fee estimation — ``BlockchainClientProtocol/estimateFee(for:)``
    /// returns current network rates and, when supported, a transaction fee
    /// estimate.
    case feeEstimation

    /// The node can page through transactions affecting an account.
    case transactionHistory

    /// The node can stream newly observed transactions or blocks affecting an account.
    case transactionSubscription
}

/// The common interface shared by every blockchain client in WalletKit.
///
/// Each conformer declares its address type, such as ``BitcoinDescriptor``,
/// ``EthereumAddress``, or ``SuiAddress``. Use ``AnyBlockchainClient`` when
/// the concrete address type is not known statically.
public protocol BlockchainClientProtocol {
    /// The address type this client uses.
    associatedtype Address: BlockchainAddress

    /// Returns all token/coin balances for `owner` in a single call. Throws
    /// ``WalletKitError/unsupportedFeature`` on chains that don't support bulk
    /// balance queries — check ``isSupported(_:)`` with
    /// ``BlockchainClientFeature/allBalances`` first.
    func getAllBalances(_ owner: Address) async throws -> [String: BigUInt]

    /// Returns `owner`'s balances for the requested token identifiers.
    /// Missing entries represent a zero balance or a token that could not be
    /// read by the underlying chain client.
    func getBalances(_ owner: Address, tokens: [String]) async throws -> [String: BigUInt]

    /// Returns `owner`'s balance of `token`.
    ///
    /// - Parameters:
    ///   - owner: The account's address.
    ///   - token: A chain-specific token identifier.
    func getBalance(_ owner: Address, token: String) async throws -> BigUInt

    /// Returns `owner`'s native-token balance in the chain's smallest unit.
    func getNativeBalance(_ owner: Address) async throws -> BigUInt

    /// Returns metadata for `token` — name, symbol, decimals.
    ///
    /// - Parameter token: A chain-specific token identifier, or `nil` for the
    ///   native token.
    func getTokenInfo(_ token: String?) async throws -> TokenInfo

    /// Returns the current USD price of `token`.
    ///
    /// - Parameter token: A chain-specific token identifier, or `nil` for the
    ///   native token.
    func getTokenPrice(_ token: String?) async throws -> Decimal

    /// Returns whether `owner` has been active on this chain.
    func isActiveAccount(_ owner: Address) async throws -> Bool

    /// Returns whether this client supports `feature`.
    func isSupported(_ feature: BlockchainClientFeature) -> Bool

    /// Returns current network fee rates and, when `request` is non-nil, a
    /// per-transaction gas estimate.
    ///
    /// Pass `nil` to get only the current network rates
    /// (``FeeEstimate/gasLimit`` and ``FeeEstimate/estimatedFee`` will be
    /// `nil`). See
    /// ``FeeEstimate`` for chain-specific field semantics and units.
    ///
    /// - Parameter request: A ``FeeEstimateRequest`` describing the
    ///   transaction to estimate, or `nil` for rates-only.
    /// - Returns: A ``FeeEstimate`` with gas rates and, when `request` is
    ///   non-nil, ``FeeEstimate/gasLimit`` and ``FeeEstimate/estimatedFee``.
    /// - Throws: ``BlockchainClientError`` on a transport, RPC, or decoding
    ///   failure.
    func estimateFee(for request: FeeEstimateRequest<Address>?) async throws -> FeeEstimate

    /// Broadcasts a signed transaction and returns its identifier.
    ///
    /// - Parameters:
    ///   - transaction: The unsigned transaction bytes, when required by the
    ///     chain.
    ///   - signature: The signed transaction data.
    /// - Returns: The transaction identifier.
    /// - Throws: ``BlockchainClientError`` on a transport or RPC failure, or
    ///   when the node rejects the transaction.
    func broadcast(transaction: Data, signature: Data) async throws -> String

    /// Returns one bounded page of account activity. The cursor is opaque and
    /// must be persisted unchanged by callers.
    func transactionHistory(
        _ owner: Address,
        request: BlockchainTransactionHistoryRequest
    ) async throws -> BlockchainTransactionPage

    /// Streams newly observed heads when the node supports a live transport.
    func transactionHeads(_ owner: Address) -> AsyncThrowingStream<BlockchainTransactionHead, any Swift.Error>
}

public extension BlockchainClientProtocol {
    /// Clients opt in when their node exposes a safe account-history API.
    func transactionHistory(
        _ owner: Address,
        request: BlockchainTransactionHistoryRequest
    ) async throws -> BlockchainTransactionPage {
        throw WalletKitError.unsupportedFeature
    }

    func transactionHeads(_ owner: Address) -> AsyncThrowingStream<BlockchainTransactionHead, any Swift.Error> {
        AsyncThrowingStream { continuation in
            continuation.finish(throwing: WalletKitError.unsupportedFeature)
        }
    }
}
