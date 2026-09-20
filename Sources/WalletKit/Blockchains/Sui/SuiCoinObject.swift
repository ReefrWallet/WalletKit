//
//  SuiCoinObject.swift
//  WalletKit
//
//  Created by Andrey Yurkevich on 28/08/2026.
//  Copyright © 2026 Reefr Wallet. All rights reserved.
//

import Foundation

/// An on-chain Sui `Coin<T>` object owned by an address, as returned by
/// ``SuiGRPCClient/ownedCoins(of:coinType:)``.
///
/// Carries the ``reference`` needed to include the coin as a PTB object
/// input (``SuiObjectReference`` is the BCS-encoded object reference the
/// `UnsignedSui*` builders use), plus the coin's current ``balance`` in
/// the coin's smallest unit.
public struct SuiCoinObject: Sendable {
    /// The reference identifying this specific version of the coin on-chain.
    public let reference: SuiObjectReference
    /// The coin's current balance, in the coin type's smallest unit
    /// (e.g. MIST for SUI).
    public let balance: UInt64

    public init(reference: SuiObjectReference, balance: UInt64) {
        self.reference = reference
        self.balance = balance
    }
}
