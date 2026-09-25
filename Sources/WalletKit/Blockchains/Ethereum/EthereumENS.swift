//
//  EthereumENS.swift
//  WalletKit
//
//  Created by Andrey Yurkevich on 22/08/2026.
//  Copyright © 2026 Reefr Wallet. All rights reserved.
//

import Foundation
import WalletKitRust

/// ENS (Ethereum Name Service) name hashing — backs
/// ``EthereumRPCClient/chainlinkFeedAddress(base:quote:ensRegistry:)``, which resolves
/// a Chainlink feed's ENS name (e.g. `"eth-usd.data.eth"`) to a node hash
/// before looking it up through the ENS Registry.
public enum EthereumENS {
    /// Computes the EIP-137 namehash of `name` — the recursive
    /// Keccak-256 ENS uses to turn a dotted name into the 32-byte `node`
    /// its Registry and resolver contracts key on.
    ///
    /// - Parameter name: The dotted ENS name (e.g. `"eth-usd.data.eth"`).
    /// - Returns: The 32-byte node hash.
    public static func namehash(_ name: String) -> Data {
        let labels = name.split(separator: ".").reversed()

        return labels.reduce(Data(repeating: 0, count: 32)) { node, label in
            ethereumKeccak256(data: node + ethereumKeccak256(data: Data(label.utf8)))
        }
    }
}
