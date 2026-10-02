//
//  SuiDappChainTypes.swift
//  WalletKit
//
//  Created by Andrey Yurkevich on 02/10/2026.
//  Copyright © 2026 Reefr Wallet. All rights reserved.
//
//  Clean Swift types for the chain lookups a dapp's unresolved
//  `Transaction` JSON needs (object owner/version, a Move function's
//  parameter types, gas simulation) — ``SuiGRPCClient`` converts its raw
//  generated gRPC types into these so no `WalletKitGRPC` type needs to
//  cross the module boundary into the app layer.

import Foundation

/// `SuiGRPCClient/objects(ids:readMask:)`'s per-object result.
public struct SuiObjectInfo: Sendable, Equatable {
    /// An object's on-chain owner — mirrors `Owner::OwnerKind`, minus
    /// `CONSENSUS_ADDRESS`, which isn't a plain address/object/shared
    /// owner this codebase's `CallArg` encoding has a shape for.
    public enum Owner: Sendable, Equatable {
        case address(SuiAddress)
        case object(SuiAddress)
        case immutable
        case shared(initialSharedVersion: UInt64)
        case unsupported
    }

    public let objectId: Data
    public let version: UInt64
    public let digest: Data
    public let owner: Owner

    public init(objectId: Data, version: UInt64, digest: Data, owner: Owner) {
        self.objectId = objectId
        self.version = version
        self.digest = digest
        self.owner = owner
    }
}

/// A Move value type, as it appears in a function's parameter list —
/// mirrors `OpenSignatureBody::Type`. `unsupported` covers both
/// `TYPE_UNKNOWN` and any future type this reader doesn't recognize.
public indirect enum SuiMoveTypeBody: Sendable, Equatable {
    case address
    case bool
    case u8, u16, u32, u64, u128, u256
    case vector(SuiMoveTypeBody)
    case datatype(typeName: String, typeParameters: [SuiMoveTypeBody])
    case typeParameter(Int)
    case unsupported
}

/// A single formal parameter of a `SuiMoveFunctionSignature` — mirrors
/// `OpenSignature`.
public struct SuiMoveParameter: Sendable, Equatable {
    public enum Reference: Sendable, Equatable {
        case none
        case immutable
        case mutable
    }

    public let reference: Reference
    public let body: SuiMoveTypeBody

    public init(reference: Reference, body: SuiMoveTypeBody) {
        self.reference = reference
        self.body = body
    }
}

/// `SuiGRPCClient/moveFunction(package:module:name:)`'s result — only
/// `parameters` is surfaced; nothing here needs the function's return
/// types or visibility.
public struct SuiMoveFunctionSignature: Sendable, Equatable {
    public let parameters: [SuiMoveParameter]

    public init(parameters: [SuiMoveParameter]) {
        self.parameters = parameters
    }
}

/// `SuiGRPCClient/gasCostSummary(transactionData:)`'s result — mirrors
/// `GasCostSummary`'s three cost fields (`non_refundable_storage_fee`
/// isn't needed for gas-budget sizing).
public struct SuiGasCostSummary: Sendable, Equatable {
    public let computationCost: UInt64
    public let storageCost: UInt64
    public let storageRebate: UInt64

    public init(computationCost: UInt64, storageCost: UInt64, storageRebate: UInt64) {
        self.computationCost = computationCost
        self.storageCost = storageCost
        self.storageRebate = storageRebate
    }
}
