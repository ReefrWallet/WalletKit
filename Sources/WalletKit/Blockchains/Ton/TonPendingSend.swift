//
//  TonPendingSend.swift
//  WalletKit
//
//  Copyright © 2026 Reefr Wallet. All rights reserved.
//

import Foundation

/// A signed TON request kept until its outcome is known, so it survives an app restart.
///
/// The wallet accepts exactly one message per `seqno`, so a pending send is also the reservation of that
/// `seqno`: no second request is signed while this one is unresolved.
public struct TonPendingSend: Codable, Equatable, Sendable {
    /// The TEP-467 normalized hash of the external message, hex encoded.
    public let normalizedHash: String
    public let sender: String
    public let seqno: UInt32
    /// BoC of the signed external message, resent unchanged while it can still be processed.
    public let signedMessage: Data
    /// Unix time after which the wallet rejects the request.
    public let validUntil: UInt32

    public init(normalizedHash: String, sender: String, seqno: UInt32, signedMessage: Data, validUntil: UInt32) {
        self.normalizedHash = normalizedHash
        self.sender = sender
        self.seqno = seqno
        self.signedMessage = signedMessage
        self.validUntil = validUntil
    }
}

/// What a check of a ``TonPendingSend`` found.
public enum TonSendOutcome: Equatable, Sendable {
    /// The wallet's transaction for the request is indexed.
    case confirmed
    /// The request can still be processed: its `seqno` is current and it has not expired. It was resent.
    case pending
    /// Nothing can process it any more, and no transaction for it exists: safe to sign a replacement.
    case unprocessed
    /// The wallet's `seqno` moved past the request but its transaction is not indexed yet. It may have been
    /// processed, so no replacement is signed.
    case unresolved
}

public enum TonSendError: Error, Equatable {
    /// An earlier send from this wallet has no known outcome yet.
    case unresolvedPendingSend
}

extension TonSendError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .unresolvedPendingSend: "An earlier TON transfer from this account is still being confirmed."
        }
    }
}

public extension TonUnsignedTransaction {
    /// The record to persist before submitting `signature`'s message.
    func pendingSend(signature: Data) throws -> TonPendingSend {
        try TonPendingSend(
            normalizedHash: normalizedHash(signature: signature),
            sender: sender,
            seqno: seqno,
            signedMessage: signedMessage(signature: signature),
            validUntil: validUntil
        )
    }
}

public extension TonClient {
    /// How long after expiry an unindexed request is still treated as possibly processed, covering indexer lag.
    static let indexingGrace: TimeInterval = 120

    /// Whether a failed submission may still have reached the network: a transport or quota failure or a node
    /// error. Anything else is a definite rejection.
    static func isAmbiguous(_ error: any Swift.Error) -> Bool {
        switch error as? BlockchainClientError {
        case .transportError, .quotaExceeded: true
        case let .rpcError(code, _)?: code >= 500 || code == 0
        default: false
        }
    }

    /// Submits `pending` for the first time. A definite rejection is thrown; an ambiguous failure is thrown
    /// too, and the caller keeps the record and calls ``reconcile(_:now:)`` later.
    func submit(_ pending: TonPendingSend) async throws {
        try await postBoc(pending.signedMessage)
    }

    /// Reads the wallet's state first, then acts on what it finds:
    /// - `seqno` still the request's: resend the same message while unexpired, else it is ``TonSendOutcome/unprocessed``.
    /// - `seqno` moved on: ``TonSendOutcome/confirmed`` if the message is indexed; else ``TonSendOutcome/unresolved``
    ///   until the expiry plus ``indexingGrace`` has passed, then ``TonSendOutcome/unprocessed``.
    func reconcile(_ pending: TonPendingSend, now: Date = Date()) async throws -> TonSendOutcome {
        let sender = try TonAddress(string: pending.sender)
        let current = try await seqno(sender)
        let expiry = Date(timeIntervalSince1970: TimeInterval(pending.validUntil))

        if current <= pending.seqno {
            guard now < expiry else {
                return .unprocessed
            }

            try await submit(pending)
            return .pending
        }

        if try await isIndexed(messageHash: pending.normalizedHash) {
            return .confirmed
        }

        return now > expiry.addingTimeInterval(Self.indexingGrace) ? .unprocessed : .unresolved
    }

    /// Whether the indexer holds a transaction processing the message with this normalized hash.
    func isIndexed(messageHash: String) async throws -> Bool {
        try await transactionsProcessing(messageHash: messageHash).first != nil
    }
}
