//
//  BlockchainClientProtocol.swift
//  Reefr Wallet
//
//  Created by Andrey Yurkevich on 18.02.26.
//  Copyright © 2026 Reefr Wallet. All rights reserved.
//

@_exported import Foundation
@_exported import BigInt

/// Discrete capabilities a ``BlockchainClientProtocol`` conformer may or may
/// not support. Call ``BlockchainClientProtocol/isSupported(_:)`` before
/// using a feature to avoid ``WalletKitError/unsupportedFeature`` errors at
/// runtime.
public enum BlockchainClientFeature {
    /// Bulk balance query for a requested set of token/coin identifiers.
    case multipleBalances

    /// Bulk balance query — ``BlockchainClientProtocol/getAllBalances(_:)``
    /// returns balances for every token/coin the account holds in a single
    /// call. Supported by Sui (``SuiGRPCClient``); not supported by Ethereum
    /// (``EthereumRPCClient``), which requires a separate call per token.
    case allBalances

    /// Fee estimation — ``BlockchainClientProtocol/estimateFee(for:)``
    /// returns current network gas rates and, when a request is supplied, a
    /// per-transaction fee estimate. Supported by both ``EthereumRPCClient``
    /// (via `eth_gasPrice`/`eth_maxPriorityFeePerGas`/`eth_getBlockByNumber`/
    /// `eth_estimateGas`) and ``SuiGRPCClient`` (via `LedgerService.getEpoch`
    /// for the reference gas price and `TransactionExecutionService.
    /// simulateTransaction` for the per-tx estimate).
    case feeEstimation

    /// The node can page through transactions affecting an account.
    case transactionHistory

    /// The node can stream newly observed transactions or blocks affecting an account.
    case transactionSubscription
}

/// The common interface shared by every blockchain client in WalletKit.
///
/// Each conformer is parameterised on its chain's address type:
/// `associatedtype Address: BlockchainAddress`. This keeps account-address
/// parameters type-safe (``EthereumAddress`` on Ethereum, ``SuiAddress`` on
/// Sui) while sharing a single protocol.
///
/// **Type erasure:** Because the protocol has an associated type, it cannot be
/// used directly as an existential (`any BlockchainClientProtocol`). Use
/// ``AnyBlockchainClient`` — the String-based type-eraser returned by
/// `BlockchainClientProvider.getClient(blockchain:)` — for existential
/// consumers that don't care about the concrete address type.
///
/// **`token` stays `String`:** Only account-owner parameters become `Address`.
/// Token/coin identifiers (`token: String`) remain stringly-typed because on
/// Sui a coin type is a fully-qualified module path like `0x2::sui::SUI`, not
/// an address; there is no single `Address` type that covers both.
public protocol BlockchainClientProtocol {
    /// The address type this client's chain uses — ``EthereumAddress`` for
    /// EVM-compatible chains or ``SuiAddress`` for Sui.
    associatedtype Address: BlockchainAddress

    /// Returns all token/coin balances for `owner` in a single call. Throws
    /// ``WalletKitError/unsupportedFeature`` on chains that don't support bulk
    /// balance queries — check ``isSupported(_:)`` with
    /// ``BlockchainClientFeature/allBalances`` first.
    func getAllBalances(_ owner: Address) async throws -> [String: BigUInt]

    /// Returns `owner`'s balances for the requested ERC-20/coin identifiers.
    /// Missing entries represent a zero balance or a token that could not be
    /// read by the underlying chain client.
    func getBalances(_ owner: Address, tokens: [String]) async throws -> [String: BigUInt]

    /// Returns `owner`'s balance of the ERC-20/coin at `token`.
    ///
    /// - Parameters:
    ///   - owner: The account's address.
    ///   - token: The ERC-20 contract address or Sui coin-type string.
    func getBalance(_ owner: Address, token: String) async throws -> BigUInt

    /// Returns `owner`'s native-token balance (ETH in wei, SUI in MIST).
    func getNativeBalance(_ owner: Address) async throws -> BigUInt

    /// Returns metadata for `token` — name, symbol, decimals.
    ///
    /// - Parameter token: The token contract address or coin-type string. Pass
    ///   `nil` for the chain's native token.
    func getTokenInfo(_ token: String?) async throws -> TokenInfo

    /// Returns the current USD price of `token`.
    ///
    /// - Parameter token: The token contract address or coin-type string. Pass
    ///   `nil` for the chain's native token.
    func getTokenPrice(_ token: String?) async throws -> Decimal

    /// Returns whether `owner` has been active on this chain.
    func isActiveAccount(_ owner: Address) async throws -> Bool

    /// Returns whether this client supports `feature`.
    func isSupported(_ feature: BlockchainClientFeature) -> Bool

    /// Returns current network fee rates and, when `request` is non-nil, a
    /// per-transaction gas estimate.
    ///
    /// Pass `nil` to get only the current network rates (``FeeEstimate/
    /// gasLimit`` and ``FeeEstimate/estimatedFee`` will be `nil`). See
    /// ``FeeEstimate`` for chain-specific field semantics and units.
    ///
    /// - Parameter request: A ``FeeEstimateRequest`` describing the
    ///   transaction to estimate, or `nil` for rates-only.
    /// - Returns: A ``FeeEstimate`` with gas rates and, when `request` is
    ///   non-nil, ``FeeEstimate/gasLimit`` and ``FeeEstimate/estimatedFee``.
    /// - Throws: ``BlockchainClientError`` on a transport, RPC, or decoding
    ///   failure.
    func estimateFee(for request: FeeEstimateRequest<Address>?) async throws -> FeeEstimate

    /// Broadcasts a signed transaction and returns its hash / digest.
    ///
    /// The meaning of the two parameters differs per chain:
    ///
    /// - **Ethereum**: `signature` is the complete signed transaction envelope
    ///   (as returned by ``Signer/sign(transaction:)``). `transaction`
    ///   (the unsigned bytes) is unused — pass it through for API symmetry.
    /// - **Sui**: `transaction` is the unsigned BCS-encoded `TransactionData`
    ///   and `signature` is the serialized Sui signature returned by
    ///   ``Signer/sign(transaction:)``.
    ///
    /// - Parameters:
    ///   - transaction: The unsigned transaction bytes (used on Sui; ignored
    ///     on Ethereum).
    ///   - signature: The signed transaction envelope (Ethereum) or the
    ///     serialized Sui signature (Sui).
    /// - Returns: The transaction hash (Ethereum) or digest (Sui).
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
