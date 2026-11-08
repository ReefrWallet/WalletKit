//
//  SuiSubmission.swift
//  WalletKit
//
//  Created by Andrey Yurkevich on 08/11/2026.
//  Copyright © 2026 Reefr Wallet. All rights reserved.
//
//  Restart-safe follow-up of a signed staking transaction. The complete
//  signed submission is persisted by the app before the first broadcast;
//  everything here decides, from chain evidence only, what became of it.
//
//  Non-inclusion is proven, never assumed: a missing transaction proves
//  nothing by itself. A transaction mutates its gas coin whenever it
//  executes, so once it has expired, an unchanged gas coin proves it never
//  ran, and a gas coin spent by a different finalized transaction proves the
//  same. A scan of every checkpoint in the validity window would also prove
//  it, but a window spans around half a million checkpoints, so it is not
//  attempted: such a submission stays unresolved.

import Foundation

/// An object a transaction consumes or mutates, as it was when the transaction was built.
public struct SuiInputRef: Sendable, Equatable, Codable {
    /// Base58, as the node reports it.
    public let digest: String
    public let objectId: String
    public let version: UInt64

    public init(_ reference: SuiObjectReference) {
        objectId = reference.objectId.hexEncoded
        version = reference.version
        digest = Base58.encode(reference.digest)
    }

    public func reference() throws -> SuiObjectReference {
        SuiObjectReference(objectId: try Data(hexString: objectId), version: version, digest: try Base58.decode(digest))
    }
}

/// A signed transaction, stored in full so it can be resumed or rebroadcast byte for byte.
public struct SuiPendingSubmission: Sendable, Equatable, Codable {
    public let chainId: String
    public let createdAt: Date
    /// Base58 transaction digest.
    public let digest: String
    /// The transaction is invalid once the chain's epoch is greater than this.
    public let expiryEpoch: UInt64
    public let inputs: [SuiInputRef]
    public let kind: SuiStakingActionKind
    public let signature: Data
    /// The latest executed checkpoint read before the first broadcast.
    public let startCheckpoint: UInt64
    public let transactionData: Data

    public init(prepared: SuiPreparedStaking, signature: Data, createdAt: Date) {
        chainId = prepared.chainId
        self.createdAt = createdAt
        digest = Base58.encode(prepared.digest)
        expiryEpoch = prepared.expirationEpoch
        inputs = prepared.inputs
        kind = prepared.action.kind
        self.signature = signature
        startCheckpoint = prepared.startCheckpoint
        transactionData = prepared.transactionData
    }
}

public enum SuiSubmissionResolution: Sendable, Equatable {
    /// The transaction failed on chain (gas was charged).
    case failed(String)
    /// Proven not to have executed, and it never will.
    case notExecuted(NotExecutedReason)
    case succeeded
    /// Not decided; the submission stays pending and the account stays locked.
    case unresolved(UnresolvedReason)

    public enum NotExecutedReason: Sendable, Equatable {
        /// Expired while every input was still at the version it was built against.
        case inputsUntouched
        /// Expired, and a different finalized transaction consumed one of its exact inputs.
        case inputSpentElsewhere(by: String)
    }

    public enum UnresolvedReason: Sendable, Equatable {
        case chainMismatch
        /// Expired, but no proof of non-execution is available.
        case expiredWithoutProof
        /// The node no longer serves history back to the broadcast, so "not found" means nothing.
        case historyPruned
        case nodeUnavailable
        /// Still within its validity window; it may yet be executed.
        case stillValid
    }
}

/// What to do with a persisted submission after a failed broadcast.
public enum SuiBroadcastDecision: Sendable, Equatable {
    case keepPending
    /// Only for a rejection that depends on no chain state at all.
    case release
}

public enum SuiBroadcastPolicy {
    private static let invalidArgumentStatus = 3
    private static let statelessMarkers = ["malformed", "deserializ", "invalid transaction data"]

    /// Only a stateless rejection of the original send, in the process that made it, releases the
    /// submission. Everything else, above all any state-dependent rejection and any rebroadcast of a
    /// persisted submission, keeps it pending: the app may have quit after the node received the first
    /// send, so a retry's "already spent" says nothing about what happened to that send.
    public static func decision(for error: Error, isOriginalSendInThisProcess: Bool) -> SuiBroadcastDecision {
        guard
            isOriginalSendInThisProcess,
            case let BlockchainClientError.rpcError(code, message) = error,
            code == invalidArgumentStatus
        else {
            return .keepPending
        }

        let text = message.lowercased()
        return statelessMarkers.contains { text.contains($0) } ? .release : .keepPending
    }
}

public enum SuiBroadcastResult: Sendable, Equatable {
    case accepted
    /// Nothing was sent: the endpoint's chain is not the one the transaction was signed for.
    case chainMismatch
    case keepPending
    case released
}

public struct SuiSubmissionResolver: Sendable {
    private let chain: any SuiStakingChain

    public init(chain: any SuiStakingChain) {
        self.chain = chain
    }

    /// Sends the exact persisted bytes, but only to an endpoint verified to be on the submission's chain.
    /// A node acknowledgement is not a result: the caller still resolves.
    public func broadcast(
        _ submission: SuiPendingSubmission, isOriginalSendInThisProcess: Bool
    ) async -> SuiBroadcastResult {
        // Verification is separate from the send: an error here means nothing was attempted, so the release
        // policy, which judges a rejection of the transaction itself, must not see it.
        do {
            guard try await chain.serviceInfo().chainId == submission.chainId else {
                return .chainMismatch
            }
        } catch {
            return .keepPending
        }

        do {
            let digest = try await chain.broadcast(
                transactionData: submission.transactionData, signature: submission.signature
            )

            return digest == submission.digest ? .accepted : .keepPending
        } catch {
            let decision = SuiBroadcastPolicy.decision(
                for: error, isOriginalSendInThisProcess: isOriginalSendInThisProcess
            )

            return decision == .release ? .released : .keepPending
        }
    }

    public func resolve(_ submission: SuiPendingSubmission) async -> SuiSubmissionResolution {
        let info: SuiServiceInfo
        let status: SuiTransactionStatus
        do {
            info = try await chain.serviceInfo()
            guard info.chainId == submission.chainId else {
                return .unresolved(.chainMismatch)
            }

            status = try await chain.transactionStatus(digest: submission.digest)
        } catch {
            return .unresolved(.nodeUnavailable)
        }

        if case let .finalized(failure) = status {
            return failure.map { .failed($0) } ?? .succeeded
        }

        guard info.epoch > submission.expiryEpoch else {
            return .unresolved(.stillValid)
        }

        // Absence is only meaningful if this node still serves the history from before the broadcast.
        guard info.lowestAvailableCheckpoint <= submission.startCheckpoint else {
            return .unresolved(.historyPruned)
        }

        return await proveNotExecuted(submission)
    }

    /// What the node says about one recorded input.
    private enum InputState {
        case changed(SuiObjectReference)
        case unchanged
        case unknown
    }

    private func proveNotExecuted(_ submission: SuiPendingSubmission) async -> SuiSubmissionResolution {
        var states: [InputState] = []
        for input in submission.inputs {
            states.append(await state(of: input))
        }

        let unchanged = states.allSatisfy { if case .unchanged = $0 { true } else { false } }
        guard !unchanged else {
            return .notExecuted(.inputsUntouched)
        }

        // Any one input spent by a different finalized transaction proves it never ran, so a failed lookup of
        // one input (a merged-away or deleted coin, a pruned history) must not stop the others being checked.
        var lookupFailed = false
        for case let .changed(recorded) in states {
            do {
                if let other = try await chain.consumingTransaction(of: recorded), other != submission.digest {
                    return .notExecuted(.inputSpentElsewhere(by: other))
                }
            } catch {
                lookupFailed = true
            }
        }

        let unknown = states.contains { if case .unknown = $0 { true } else { false } }
        return .unresolved(lookupFailed || unknown ? .nodeUnavailable : .expiredWithoutProof)
    }

    private func state(of input: SuiInputRef) async -> InputState {
        do {
            let recorded = try input.reference()
            return try await chain.liveObjectReference(id: input.objectId) == recorded ? .unchanged : .changed(recorded)
        } catch {
            return .unknown
        }
    }
}
