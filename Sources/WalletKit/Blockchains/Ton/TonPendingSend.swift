//
//  TonPendingSend.swift
//  WalletKit
//
//  Copyright © 2026 Reefr Wallet. All rights reserved.
//

import BigInt
import Foundation

/// A signed TON request kept until its outcome is known, so it survives an app restart.
///
/// The wallet accepts exactly one message per `seqno`, so a pending send is also the reservation of that
/// `seqno`: no second request is signed while this one is unresolved.
public struct TonPendingSend: Codable, Equatable, Sendable {
    /// The wallet's latest transaction when the request was built (`0` if none): where the walk to the transaction
    /// that consumed `seqno` starts. `nil` for a record without it, which can never be proven unprocessed.
    public let baselineLt: UInt64?
    /// The TEP-467 normalized hash of the external message, hex encoded.
    public let normalizedHash: String
    /// Set for a Jetton transfer.
    public let jetton: TonJettonTransfer?
    public let sender: String
    public let seqno: UInt32
    /// BoC of the signed external message, resent unchanged while it can still be processed.
    public let signedMessage: Data
    /// Unix time after which the wallet rejects the request.
    public let validUntil: UInt32

    public init(
        normalizedHash: String,
        sender: String,
        seqno: UInt32,
        signedMessage: Data,
        validUntil: UInt32,
        baselineLt: UInt64? = nil,
        jetton: TonJettonTransfer? = nil
    ) {
        self.baselineLt = baselineLt
        self.jetton = jetton
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
    /// The wallet's `seqno` moved past the request, but the transaction that consumed it could not be identified
    /// in an unbroken, fully indexed chain. It may have been processed, so no replacement is signed.
    case unresolved
}

public enum TonSendError: Error, Equatable {
    /// The request was signed for a `seqno` the wallet has moved past, so another send went first.
    case staleRequest
    /// An earlier send from this wallet has no known outcome yet.
    case unresolvedPendingSend
    /// Emulating the transfer shows its request or the sender's Jetton wallet refusing it.
    case wouldFail
    /// Sizing the attachment by emulation was interrupted after an attachment was refused, so no safe amount is known.
    case attachmentUndetermined
    /// The wallet holds less Gram than the send needs (nanograms).
    case insufficientGram(required: BigUInt, available: BigUInt)
}

extension TonSendError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .staleRequest: "The account sent another transfer meanwhile. Review and send again."
        case .unresolvedPendingSend: "An earlier TON transfer from this account is still being confirmed."
        case .wouldFail: "This transfer would be refused."
        case let .insufficientGram(required, available):
            "Not enough Gram: sending needs \(Self.gram(required)) and the account holds \(Self.gram(available))."
        case .attachmentUndetermined: "Couldn't work out how much Gram this transfer needs. Try again."
        }
    }
}

extension TonSendError {
    /// Nanograms as a whole-unit amount, for messages.
    static func gram(_ nanograms: BigUInt) -> String {
        let (whole, fraction) = nanograms.quotientAndRemainder(dividingBy: 1_000_000_000)
        var digits = String(fraction)
        digits = String(repeating: "0", count: 9 - digits.count) + digits

        while digits.hasSuffix("0") {
            digits.removeLast()
        }

        return "\(whole)\(digits.isEmpty ? "" : "." + digits) GRAM"
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
            validUntil: validUntil,
            baselineLt: baselineLt,
            jetton: jetton
        )
    }
}

public extension TonClient {
    /// Pages walked at most when proving a request unprocessed; a longer gap stays unresolved.
    static let maxContinuityPages = 20

    /// Whether a failed submission may still have reached the network: a transport or quota failure or a node
    /// error. Anything else is a definite rejection.
    static func isAmbiguous(_ error: any Swift.Error) -> Bool {
        switch error as? BlockchainClientError {
        // An unreadable answer to a request that may have been accepted proves nothing.
        case .transportError, .quotaExceeded, .decodingFailed, .invalidResponse, .serverError: true
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
    /// - `seqno` still the request's: resend the same message while unexpired by this clock. It is
    ///   ``TonSendOutcome/unprocessed`` only once the chain's own time is past the request's expiry.
    /// - `seqno` moved on: ``TonSendOutcome/confirmed`` if a transaction for the message is indexed. Otherwise the
    ///   wallet's transactions after ``TonPendingSend/baselineLt`` are walked by `prev_trans_lt` up to the chain's
    ///   latest one. Only an unbroken chain with no transaction for the message proves it unprocessed
    ///   (``TonSendOutcome/unprocessed``); any gap or lag leaves it ``TonSendOutcome/unresolved``.
    func reconcile(_ pending: TonPendingSend, now: Date = Date()) async throws -> TonSendOutcome {
        let sender = try TonAddress(string: pending.sender)
        let information = try await accountInformation(sender)
        let read = try await seqnoRead(sender, after: information)
        let current = read.value

        // The chain time counts only if `seqno` describes that state or a later one: then a request processed before
        // it expired shows in `seqno`. Responses of different blocks can arrive in either order, so compare blocks.
        // A wallet that isn't deployed has `seqno` 0 by its state alone; a frozen one's `seqno` can't be read.
        let seqnoIsCurrent = information.state == .nonexistent || information.state == .uninitialized
            || read.block.flatMap { block in information.masterchainBlock.map { block >= $0 } } == true
        let chainTime = seqnoIsCurrent ? information.chainTime : nil

        if current <= pending.seqno {
            // The wallet checks expiry against chain time, not this device's clock: with no chain time past
            // `validUntil` the request may still be processed, so it stays reserved.
            if let chainTime, chainTime > pending.validUntil {
                return .unprocessed
            }

            if now < Date(timeIntervalSince1970: TimeInterval(pending.validUntil)) {
                try await submit(pending)
            }

            return .pending
        }

        if try await isIndexed(messageHash: pending.normalizedHash) {
            return .confirmed
        }

        // The head comes from the state the advanced `seqno` was read from, so it includes the transaction that
        // consumed it; a separate, possibly older, account read could miss that transaction.
        guard let chainHead = read.lastTransactionLt else {
            return .unresolved
        }

        switch try await wasProcessed(pending, sender: sender, chainHead: chainHead) {
        case true?: return .confirmed
        case false?: return .unprocessed
        case nil: return .unresolved
        }
    }

    /// Walks the wallet's transactions from the baseline to `chainHead`, checking that each one's `prev_trans_lt`
    /// is the one before it. `true` if one carries the message, `false` if the chain is complete and none does,
    /// `nil` if the indexer lacks part of the chain.
    func wasProcessed(_ pending: TonPendingSend, sender: TonAddress, chainHead: UInt64) async throws -> Bool? {
        guard var previous = pending.baselineLt else {
            return nil
        }

        for _ in 0 ..< Self.maxContinuityPages {
            let page = try await indexedTransactions(of: sender, after: previous, limit: Self.historyPageLimit)

            guard !page.isEmpty else {
                return previous == chainHead ? false : nil
            }

            for transaction in page {
                guard let lt = UInt64(transaction.lt), transaction.prevTransLt.flatMap(UInt64.init) == previous else {
                    return nil
                }

                // A request the indexer lists without its normalized hash can't be told from ours.
                if transaction.isExternalRequest {
                    guard let hash = transaction.requestHash else {
                        return nil
                    }

                    if hash == pending.normalizedHash {
                        return true
                    }
                }

                previous = lt
            }

            if previous >= chainHead {
                return previous == chainHead ? false : nil
            }
        }

        return nil
    }

    /// Whether the indexer holds a transaction processing the message with this normalized hash.
    func isIndexed(messageHash: String) async throws -> Bool {
        try await transactionsProcessing(messageHash: messageHash).first != nil
    }
}
