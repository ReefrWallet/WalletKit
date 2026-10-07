//
//  StringAddressing.swift
//  WalletKit
//
//  Created by Andrey Yurkevich on 27/08/2026.
//  Copyright © 2026 Reefr Wallet. All rights reserved.
//

import BigInt
import Foundation

// MARK: - BlockchainClientProtocol

/// String-addressed forwarding for ``BlockchainClientProtocol``.
///
/// None of these signatures mention `Address`, so they can be called on an
/// `any BlockchainClientProtocol` existential whose concrete address type
/// isn't known statically. Each one parses its address strings with
/// ``BlockchainClientProtocol/makeAddress(_:)`` and forwards to the typed
/// requirement.
public extension BlockchainClientProtocol {
    /// Parses `string` with `Address(string:)`.
    func makeAddress(_ string: String) throws -> Address {
        try Address(string: string)
    }

    /// Returns all token balances for `owner`. Throws
    /// ``WalletKitError/unsupportedFeature`` on chains that don't support
    /// bulk balance queries (check ``isSupported(_:)`` with
    /// ``BlockchainClientFeature/allBalances`` first).
    ///
    /// - Parameter owner: The account's address string.
    func getAllBalances(_ owner: String) async throws -> [String: BigUInt] {
        try await getAllBalances(makeAddress(owner))
    }

    /// Returns balances for the requested token identifiers.
    ///
    /// - Parameter owner: The account's address string.
    func getBalances(_ owner: String, tokens: [String]) async throws -> [String: BigUInt] {
        try await getBalances(makeAddress(owner), tokens: tokens)
    }

    /// Returns `owner`'s balance of `token`.
    ///
    /// - Parameters:
    ///   - owner: The account's address string.
    ///   - token: A chain-specific token identifier.
    func getBalance(_ owner: String, token: String) async throws -> BigUInt {
        try await getBalance(makeAddress(owner), token: token)
    }

    /// Returns `owner`'s native-token balance in the chain's smallest unit.
    ///
    /// - Parameter owner: The account's address string.
    func getNativeBalance(_ owner: String) async throws -> BigUInt {
        try await getNativeBalance(makeAddress(owner))
    }

    /// Returns whether `owner` has been active on this chain.
    ///
    /// - Parameter owner: The account's address string.
    func isActiveAccount(_ owner: String) async throws -> Bool {
        try await isActiveAccount(makeAddress(owner))
    }

    /// Returns one bounded page of account activity.
    ///
    /// - Parameter owner: The account's address string.
    func transactionHistory(
        _ owner: String,
        request: BlockchainTransactionHistoryRequest
    ) async throws -> BlockchainTransactionPage {
        try await transactionHistory(makeAddress(owner), request: request)
    }

    /// Streams newly observed heads for `owner`. The stream finishes with
    /// ``WalletKitError/invalidAddress(reason:)`` if `owner` can't be parsed.
    ///
    /// - Parameter owner: The account's address string.
    func transactionHeads(_ owner: String) -> AsyncThrowingStream<BlockchainTransactionHead, any Swift.Error> {
        guard let address = try? makeAddress(owner) else {
            return AsyncThrowingStream { continuation in
                continuation.finish(throwing: WalletKitError.invalidAddress(reason: "Invalid account address"))
            }
        }

        return transactionHeads(address)
    }
}

// MARK: - BlockchainTransactionBuilderProtocol

/// String-addressed forwarding for ``BlockchainTransactionBuilderProtocol``,
/// callable on an `any BlockchainTransactionBuilderProtocol` existential.
public extension BlockchainTransactionBuilderProtocol {
    /// Parses `string` with `Address(string:)`.
    func makeAddress(_ string: String) throws -> Address {
        try Address(string: string)
    }

    /// Builds unsigned transaction bytes, parsing `sender` and `recipient`
    /// with ``BlockchainTransactionBuilderProtocol/makeAddress(_:)``.
    ///
    /// - Parameters:
    ///   - sender: The sending address as a string.
    ///   - recipient: The destination address as a string.
    ///   - amount: The transfer amount in the token's smallest unit.
    ///   - token: `nil` for the native token; a chain-specific token
    ///     identifier string otherwise.
    ///   - options: Builder flags — see ``BlockchainTransactionBuilderOptions``.
    /// - Returns: Unsigned transaction bytes ready for signing.
    /// - Throws: ``WalletKitError/invalidAddress(reason:)`` if `sender` or
    ///   `recipient` can't be parsed, ``BlockchainTransactionBuilderError``
    ///   on build failures, or ``BlockchainClientError`` on chain client
    ///   failures.
    func buildTransfer(
        sender: String,
        recipient: String,
        amount: BigUInt,
        token: String?,
        options: [BlockchainTransactionBuilderOptions] = []
    ) async throws -> Data {
        try await buildTransfer(
            sender: makeAddress(sender),
            recipient: makeAddress(recipient),
            amount: amount,
            token: token,
            options: options
        )
    }
}
