//
//  Blake2b256.swift
//  WalletKit
//
//  Created by Andrey Yurkevich on 08/11/2026.
//  Copyright © 2026 Reefr Wallet. All rights reserved.
//
//  Blake2b-256, computed by the Rust FFI so Swift and the signing and
//  address code share one implementation.

import Foundation
import WalletKitRust

enum Blake2b256 {
    /// The 32-byte Blake2b digest of `data`.
    static func hash(_ data: Data) -> Data {
        blake2b256(data: data)
    }
}
