//
//  Signer.swift
//  WalletKit
//
//  Created by Andrey Yurkevich on 17/08/2026.
//  Copyright © 2026 Reefr Wallet. All rights reserved.
//
import Foundation

/// Derives the address for, and signs transactions on behalf of, one
/// account on one blockchain. A conformer is bound to its key source (a
/// ``PrivateKey``, a ``HardwareDevice``) at construction, so signing is
/// always possible — there is no "signer that can't sign" state.
public protocol Signer {
    /// The chain-specific address type this signer produces.
    associatedtype Address: BlockchainAddress

    /// The account this signer signs for.
    var account: Account { get }

    /// Derives this signer's account's address.
    ///
    /// - Returns: The account's chain-specific address.
    func address() throws -> Address

    /// Signs `transaction` with this signer's key.
    ///
    /// - Parameter transaction: The chain-specific unsigned transaction
    ///   encoding to sign.
    /// - Returns: The chain-specific signed transaction encoding.
    func sign(transaction: Data) async throws -> Data
}

public extension Signer {
    /// The blockchain this signer is scoped to — ``account``'s blockchain.
    var blockchain: Blockchain { account.blockchain }
}
