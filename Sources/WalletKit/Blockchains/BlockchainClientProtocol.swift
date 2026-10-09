//
//  BlockchainClientProtocol.swift
//  Reefr Wallet
//
//  Created by Andrey Yurkevich on 18.02.26.
//  Copyright © 2026 Reefr Wallet. All rights reserved.
//

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

    /// The node can page through transactions affecting an account.
    case transactionHistory

    /// The node can stream newly observed transactions or blocks affecting an account.
    case transactionSubscription
}

/// The common interface shared by every blockchain client in WalletKit.
///
/// Each conformer declares its address type, such as ``BitcoinDescriptor``,
/// ``EthereumAddress``, or ``SuiAddress``. When the concrete address type is
/// not known statically, hold an `any BlockchainClientProtocol` and use the
/// String-addressed overloads (e.g. `getNativeBalance(_: String)`), which
/// parse addresses with ``makeAddress(_:)``.
public protocol BlockchainClientProtocol: Sendable {
    /// The address type this client uses.
    associatedtype Address: BlockchainAddress

    /// Parses `string` as this client's address type. Defaults to
    /// `Address(string:)`; conformers override it when parsing needs
    /// client context (e.g. ``BitcoinClient``'s network).
    func makeAddress(_ string: String) throws -> Address

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

    /// Returns whether `owner` has been active on this chain.
    func isActiveAccount(_ owner: Address) async throws -> Bool

    /// Returns whether this client supports `feature`.
    func isSupported(_ feature: BlockchainClientFeature) -> Bool

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
