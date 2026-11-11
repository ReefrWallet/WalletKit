//
//  CardanoRootSecret.swift
//  WalletKit
//
//  Created by Andrey Yurkevich on 11/11/2026.
//

import Foundation
import WalletKitRust

/// The secret a Cardano wallet's keys derive from.
public enum CardanoRootSecret: Sendable {
    /// BIP-39 entropy, derived with the Icarus scheme (CIP-3).
    case bip39Entropy(Data)

    /// A SLIP-39 master secret, derived with SLIP-23.
    case slip39MasterSecret(Data)

    var raw: CardanoRootSecretFfi {
        switch self {
        case let .bip39Entropy(entropy): .bip39Entropy(entropy: entropy)
        case let .slip39MasterSecret(secret): .slip39MasterSecret(masterSecret: secret)
        }
    }
}
