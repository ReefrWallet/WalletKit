//
//  BlockchainTransactionBuilderProtocol.swift
//  WalletKit
//
//  Created by Andrey Yurkevich on 28/08/2026.
//  Copyright © 2026 Reefr Wallet. All rights reserved.
//

import BigInt
import Foundation

// MARK: - Error

/// Errors thrown by ``BlockchainTransactionBuilderProtocol`` implementations.
public enum BlockchainTransactionBuilderError: Error, LocalizedError {
    /// The sender owns no coins of the required type, or their combined
    /// balance is less than the requested `amount`.
    case insufficientFunds(reason: String)
    /// The requested amount exceeds `UInt64.max` and cannot be encoded in
    /// the chain's native transaction format.
    case amountTooLarge
    /// The token identifier could not be interpreted for this chain (e.g.
    /// a non-address string passed as an Ethereum ERC-20 contract).
    case invalidToken(reason: String)
    /// Gas coin selection did not converge within the allowed number of
    /// re-simulation iterations. The transaction cannot be built safely.
    case gasSelectionFailed(reason: String)

    public var errorDescription: String? {
        switch self {
        case .insufficientFunds(let reason):
            return reason
        case .amountTooLarge:
            return "The requested amount exceeds the maximum encodable value for this chain."
        case .invalidToken(let reason):
            return "Invalid token: \(reason)"
        case .gasSelectionFailed(let reason):
            return "Gas selection failed: \(reason)"
        }
    }
}

// MARK: - Protocol

/// Builds unsigned transaction bytes for a token transfer, ready to pass
/// directly to ``Signer/sign(transaction:)``.
///
/// Implementations obtain the chain context needed to build the transaction.
/// WalletKit includes builders for Bitcoin, Cardano, Ethereum, Solana, Sui,
/// Tron, and EVM-compatible networks.
public protocol BlockchainTransactionBuilderProtocol: Sendable {
    /// The chain-specific address type.
    associatedtype Address: BlockchainAddress

    /// Parses `string` as this builder's address type. Defaults to
    /// `Address(string:)`; conformers override it when parsing needs
    /// builder context (e.g. ``BitcoinTransactionBuilder``'s network).
    func makeAddress(_ string: String) throws -> Address

    /// Builds unsigned transaction bytes encoding a transfer of `amount`
    /// of `token` (or the native asset when `token` is `nil`) from
    /// `sender` to `recipient`.
    ///
    /// All on-chain context (nonce, gas price, coin references, gas
    /// estimation) is fetched internally; the caller only supplies the
    /// four transfer parameters.
    ///
    /// - Parameters:
    ///   - sender: The sending address.
    ///   - recipient: The destination address.
    ///   - amount: The transfer amount in the token's smallest unit.
    ///   - token: A chain-specific token identifier, or `nil` for the native
    ///     token.
    ///   - options: Chain-specific transaction-building options.
    /// - Returns: Unsigned transaction bytes, ready for
    ///   ``Signer/sign(transaction:)``.
    /// - Throws: ``BlockchainTransactionBuilderError`` when the transfer
    ///   can't be built (insufficient funds, bad token identifier, etc.),
    ///   or ``BlockchainClientError`` on a chain client failure.
    func buildTransfer(
        sender: Address,
        recipient: Address,
        amount: BigUInt,
        token: String?,
        options: [BlockchainTransactionBuilderOptions]
    ) async throws -> Data
}

// MARK: - Default options shim

public extension BlockchainTransactionBuilderProtocol {
    /// Builds a transfer with default options.
    func buildTransfer(
        sender: Address,
        recipient: Address,
        amount: BigUInt,
        token: String?
    ) async throws -> Data {
        try await buildTransfer(sender: sender, recipient: recipient, amount: amount, token: token, options: [])
    }
}
