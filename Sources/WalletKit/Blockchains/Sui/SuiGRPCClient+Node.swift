//
//  SuiGRPCClient+Node.swift
//  WalletKit
//
//  Created by Andrey Yurkevich on 08/11/2026.
//  Copyright © 2026 Reefr Wallet. All rights reserved.
//
//  The node reads staking preparation and submission recovery depend on,
//  behind ``SuiStakingChain`` so both can be tested without a network.

import Foundation
import GRPCCore
import SwiftProtobuf
import WalletKitGRPC

/// What the node says about itself.
public struct SuiServiceInfo: Sendable, Equatable {
    public let chainId: String
    public let checkpointHeight: UInt64
    public let epoch: UInt64
    /// The lowest checkpoint whose transactions this node still serves.
    public let lowestAvailableCheckpoint: UInt64

    public init(chainId: String, epoch: UInt64, checkpointHeight: UInt64, lowestAvailableCheckpoint: UInt64) {
        self.chainId = chainId
        self.epoch = epoch
        self.checkpointHeight = checkpointHeight
        self.lowestAvailableCheckpoint = lowestAvailableCheckpoint
    }
}

/// The result of dry-running a transaction.
public struct SuiSimulationResult: Sendable, Equatable {
    public let failure: String?
    public let gas: SuiGasCostSummary
    /// The node's typed `INSUFFICIENT_GAS`: the budget was too small, so a larger one may succeed.
    public let isInsufficientGas: Bool
    public var isSuccess: Bool { failure == nil }

    public init(failure: String?, gas: SuiGasCostSummary, isInsufficientGas: Bool = false) {
        self.failure = failure
        self.gas = gas
        self.isInsufficientGas = isInsufficientGas
    }
}

/// What a transaction lookup found.
public enum SuiTransactionStatus: Sendable, Equatable {
    /// Executed and included in a checkpoint; `failure` is the execution error, if any.
    case finalized(failure: String?)
    /// The node reported `NOT_FOUND`. On its own this proves nothing about execution.
    case notFound
}

/// The node operations staking needs.
public protocol SuiStakingChain: Sendable {
    func broadcast(transactionData: Data, signature: Data) async throws -> String
    /// The transaction that consumed exactly `reference` (its id, version and digest) if it can be proven
    /// from finalized effects, otherwise `nil`.
    func consumingTransaction(of reference: SuiObjectReference) async throws -> String?
    /// The object's current reference, or `nil` if it no longer exists.
    func liveObjectReference(id: String) async throws -> SuiObjectReference?
    func referenceGasPrice() async throws -> UInt64
    func serviceInfo() async throws -> SuiServiceInfo
    func simulate(transactionData: Data) async throws -> SuiSimulationResult
    func suiCoins(of owner: SuiAddress) async throws -> [SuiCoinObject]
    func transactionStatus(digest: String) async throws -> SuiTransactionStatus
}

extension SuiGRPCClient: SuiStakingChain {
    /// gRPC `NOT_FOUND`.
    private static let notFoundStatus = 5
    /// How many versions back the consumer search will follow an object's history.
    private static let maxHistoryHops = 32

    public func serviceInfo() async throws -> SuiServiceInfo {
        try await withLedgerServiceClient { ledger in
            let response = try await rpc(.read) {
                try await ledger.getServiceInfo(
                    request: ClientRequest(message: Sui_Rpc_V2_GetServiceInfoRequest()),
                    options: self.callOptions
                )
            }

            return SuiServiceInfo(
                chainId: response.chainID,
                epoch: response.epoch,
                checkpointHeight: response.checkpointHeight,
                lowestAvailableCheckpoint: response.lowestAvailableCheckpoint
            )
        }
    }

    public func suiCoins(of owner: SuiAddress) async throws -> [SuiCoinObject] {
        try await ownedCoins(of: owner, coinType: "0x2::sui::SUI")
    }

    /// Dry-runs `transactionData`; an execution failure is a result, not a thrown error.
    public func simulate(transactionData: Data) async throws -> SuiSimulationResult {
        try await withTransactionExecutionServiceClient { client in
            let request = Sui_Rpc_V2_SimulateTransactionRequest.with {
                $0.transaction = Sui_Rpc_V2_Transaction.with {
                    $0.bcs = Sui_Rpc_V2_Bcs.with { $0.value = transactionData }
                }

                $0.readMask = Google_Protobuf_FieldMask.with {
                    $0.paths = ["transaction.effects.status", "transaction.effects.gas_used"]
                }
            }

            let response = try await rpc(.read) {
                try await client.simulateTransaction(
                    request: ClientRequest(message: request),
                    options: self.callOptions
                )
            }

            let effects = response.transaction.effects
            let gas = effects.gasUsed
            return SuiSimulationResult(
                failure: effects.status.success ? nil : Self.failureText(effects.status),
                gas: SuiGasCostSummary(
                    computationCost: gas.computationCost, storageCost: gas.storageCost, storageRebate: gas.storageRebate
                ),
                isInsufficientGas: !effects.status.success && effects.status.error.kind == .insufficientGas
            )
        }
    }

    private static func failureText(_ status: Sui_Rpc_V2_ExecutionStatus) -> String {
        status.error.description_p.isEmpty ? "execution failed" : status.error.description_p
    }

    public func transactionStatus(digest: String) async throws -> SuiTransactionStatus {
        do {
            let transaction = try await executedTransaction(
                digest: digest, paths: ["digest", "checkpoint", "effects.status"]
            )

            return try Self.finalizedStatus(of: transaction, expectedDigest: digest)
        } catch BlockchainClientError.rpcError(let code, _) where code == Self.notFoundStatus {
            return .notFound
        }
    }

    /// Reads a lookup result only if it is unmistakably the transaction asked for, checkpointed, with an
    /// explicit execution status: protobuf would otherwise read an omitted `success` as a failure.
    static func finalizedStatus(
        of transaction: Sui_Rpc_V2_ExecutedTransaction, expectedDigest: String
    ) throws -> SuiTransactionStatus {
        guard transaction.digest == expectedDigest else {
            throw BlockchainClientError.invalidResponse(reason: "node answered for a different transaction")
        }

        guard transaction.hasCheckpoint else {
            // Known to the node but not yet in a checkpoint: not final, so not an answer either way.
            throw BlockchainClientError.invalidResponse(reason: "transaction \(expectedDigest) is not checkpointed")
        }

        guard transaction.hasEffects, transaction.effects.hasStatus, transaction.effects.status.hasSuccess else {
            throw BlockchainClientError.invalidResponse(reason: "transaction \(expectedDigest) has no execution status")
        }

        let status = transaction.effects.status
        return .finalized(failure: status.success ? nil : failureText(status))
    }

    private func executedTransaction(digest: String, paths: [String]) async throws -> Sui_Rpc_V2_ExecutedTransaction {
        try await withLedgerServiceClient { ledger in
            let request = Sui_Rpc_V2_GetTransactionRequest.with {
                $0.digest = digest
                $0.readMask = Google_Protobuf_FieldMask.with { $0.paths = paths }
            }

            return try await rpc(.read) {
                try await ledger.getTransaction(
                    request: ClientRequest(message: request),
                    options: self.callOptions
                )
            }.transaction
        }
    }

    public func liveObjectReference(id: String) async throws -> SuiObjectReference? {
        do {
            let object = try await object(id: id)
            return SuiObjectReference(
                objectId: try Data(hexString: object.objectID),
                version: object.version,
                digest: try Base58.decode(object.digest)
            )
        } catch BlockchainClientError.rpcError(let code, _) where code == Self.notFoundStatus {
            return nil
        }
    }

    /// Follows `reference.objectId`'s history back from its live version, one producing transaction at a
    /// time, until it finds the finalized transaction whose effects consumed exactly `reference`.
    public func consumingTransaction(of reference: SuiObjectReference) async throws -> String? {
        let id = reference.objectId.hexEncoded
        let wantedDigest = Base58.encode(reference.digest)
        var version: UInt64?

        for _ in 0..<Self.maxHistoryHops {
            let object: Sui_Rpc_V2_Object
            do {
                object = try await historicalObject(id: id, version: version)
            } catch BlockchainClientError.rpcError(let code, _) where code == Self.notFoundStatus {
                // Deleted, or its history is gone: the live object is the only way in, so no proof from here.
                return nil
            }

            guard object.version > reference.version, !object.previousTransaction.isEmpty else {
                return nil
            }

            let transaction = try await executedTransaction(
                digest: object.previousTransaction, paths: ["digest", "checkpoint", "effects.changed_objects"]
            )

            guard
                transaction.hasCheckpoint,
                let change = transaction.effects.changedObjects.first(where: { $0.objectID == id }),
                change.inputState == .exists
            else {
                return nil
            }

            if change.inputVersion == reference.version {
                return change.inputDigest == wantedDigest ? transaction.digest : nil
            }

            guard change.inputVersion > reference.version else {
                return nil
            }

            version = change.inputVersion
        }

        return nil
    }

    private func historicalObject(id: String, version: UInt64?) async throws -> Sui_Rpc_V2_Object {
        try await withLedgerServiceClient { client in
            let request = Sui_Rpc_V2_GetObjectRequest.with {
                $0.objectID = id
                if let version {
                    $0.version = version
                }

                $0.readMask = Google_Protobuf_FieldMask.with {
                    $0.paths = ["object_id", "version", "previous_transaction"]
                }
            }

            return try await rpc(.read) {
                try await client.getObject(
                    request: ClientRequest(message: request),
                    options: self.callOptions
                )
            }.object
        }
    }
}
