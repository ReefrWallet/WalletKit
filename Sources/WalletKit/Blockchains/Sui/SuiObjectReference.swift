//
//  SuiObjectReference.swift
//  WalletKit
//
//  Created by Andrey Yurkevich on 28/08/2026.
//  Copyright © 2026 Reefr Wallet. All rights reserved.
//

import Foundation

/// A `(objectId, version, digest)` triple that identifies a specific
/// version of an on-chain Sui object — what a transaction's gas payment
/// (and any other object input) references.
///
/// Used by the `UnsignedSui*` transaction builders and returned by
/// ``SuiGRPCClient/ownedCoins(of:coinType:)`` as part of
/// ``SuiCoinObject/reference``.
public struct SuiObjectReference: Sendable {
    /// The object's ID as 32 raw bytes (not `0x`-prefixed).
    public let objectId: Data
    /// The object's sequence number / version.
    public let version: UInt64
    /// The object's content digest as raw bytes (Base58-decoded from the
    /// gRPC API's `digest` field).
    public let digest: Data

    public init(objectId: Data, version: UInt64, digest: Data) {
        self.objectId = objectId
        self.version = version
        self.digest = digest
    }
}
