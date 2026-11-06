// Tests of what becomes of a staking transaction: status levels and the proof of expiry.

import Foundation
import Testing
@testable import WalletKit

@Suite(.timeLimit(.minutes(1)))
struct SolanaSubmissionTests {
    private let signature = "SIG"

    private func statusJSON(_ status: String?, err: Bool = false) -> String {
        let confirmation = status.map { #""\#($0)""# } ?? "null"
        let error = err ? #"{"InstructionError":[0,"Custom"]}"# : "null"
        return #"""
        {"context":{"slot":1},"value":[{"confirmationStatus":\#(confirmation),"confirmations":1,
         "err":\#(error),"slot":1,"status":{"Ok":null}}]}
        """#
    }

    private let noStatus = #"{"context":{"slot":1},"value":[null]}"#

    @Test func confirmedAndFinalizedResolve() async throws {
        for level in ["confirmed", "finalized"] {
            let node = FakeSolanaNode()
            node.on("getSignatureStatuses", result: statusJSON(level))

            #expect(try await node.client().signatureStatus(signature, searchHistory: true) == .confirmed)
        }
    }

    @Test func errOnlyFailsOnceConfirmed() async throws {
        let node = FakeSolanaNode()
        node.on("getSignatureStatuses", result: statusJSON("confirmed", err: true))
        #expect(try await node.client().signatureStatus(signature, searchHistory: true) == .failed)
    }

    @Test(arguments: ["processed", nil] as [String?])
    func lowerLevelsStayPendingEvenWithAnError(level: String?) async throws {
        for err in [false, true] {
            let node = FakeSolanaNode()
            node.on("getSignatureStatuses", result: statusJSON(level, err: err))

            #expect(try await node.client().signatureStatus(signature, searchHistory: true) == .processed)
        }
    }

    // MARK: Reconcile

    /// A finalized chain of `blocks` from slot 100 / height 1000; each block's hash is `H<slot>`,
    /// and `signature` is in the block at `landedSlot`.
    private func chainNode(
        blocks: Int = 6,
        landedSlot: UInt64? = nil,
        finalizedHeight: UInt64 = 1_100,
        tamper: (@Sendable (UInt64, inout [String: Any]) -> Void)? = nil,
        refused: Set<UInt64> = []
    ) -> FakeSolanaNode {
        let node = FakeSolanaNode()
        let signature = signature

        node.on("getSignatureStatuses", result: noStatus)
        node.on("getBlockHeight", result: "\(finalizedHeight)")
        node.on("getSlot", result: "\(100 + UInt64(blocks) + 50)")

        node.on("getBlocks") { params in
            let start = (params[0] as? NSNumber)?.uint64Value ?? 0
            let end = (params[1] as? NSNumber)?.uint64Value ?? 0
            let slots = (100..<(100 + UInt64(blocks))).filter { $0 >= start && $0 <= end }
            return "[\(slots.map(String.init).joined(separator: ","))]"
        }

        node.on("getBlock") { params in
            let slot = (params[0] as? NSNumber)?.uint64Value ?? 0

            guard slot >= 100, slot < 100 + UInt64(blocks), !refused.contains(slot) else {
                return nil
            }

            var block: [String: Any] = [
                "blockHeight": 1_000 + (slot - 100),
                "blockhash": "H\(slot)",
                "previousBlockhash": "H\(slot - 1)",
                "signatures": slot == landedSlot ? [signature] : ["other"]
            ]

            tamper?(slot, &block)

            return (try? JSONSerialization.data(withJSONObject: block)).flatMap { String(data: $0, encoding: .utf8) }
        }

        return node
    }

    private func pending(
        lastValid: UInt64 = 1_005,
        slot: UInt64 = 100,
        cursor: SolanaPendingSubmission.ExpiryCursor? = nil
    ) -> SolanaPendingSubmission {
        SolanaPendingSubmission(
            action: .unstake(accounts: ["a"]),
            cursor: cursor,
            lastValidBlockHeight: lastValid,
            recentBlockhash: "H100",
            signature: signature,
            slotAtBuild: slot
        )
    }

    private func isUnresolved(_ update: SolanaSubmissionUpdate) -> Bool {
        if case .unresolved = update {
            return true
        }

        return false
    }

    @Test func aProcessedStatusStaysUnresolvedAndAProcessedForkDisappearing() async {
        let node = FakeSolanaNode()
        node.on("getSignatureStatuses", result: statusJSON("processed"))

        #expect(isUnresolved(await node.client().reconcile(pending())))

        // The fork is dropped: the status is gone, and the chain hasn't passed validity.
        node.on("getSignatureStatuses", result: noStatus)
        node.on("getBlockHeight", result: "1000")

        let update = await node.client().reconcile(pending())

        #expect(isUnresolved(update))
        #expect(update != .confirmed)
        #expect(update != .expired)
    }

    @Test func aNullStatusBeforeFinalizedValidityEndsResolvesNothing() async {
        let node = chainNode(finalizedHeight: 1_005)

        guard case let .unresolved(result) = await node.client().reconcile(pending()) else {
            Issue.record("expected unresolved")
            return
        }

        #expect(!result.isPastValidity)
        #expect(node.count("getBlock") == 0)
    }

    @Test func walkingEveryBlockWithoutTheSignatureProvesExpiry() async {
        let node = chainNode()

        #expect(await node.client().reconcile(pending()) == .expired)
        #expect(node.count("getBlock") >= 6)
    }

    @Test func aNullStatusAloneNeverExpires() async {
        // Past validity, but the node can't serve blocks.
        let node = chainNode(refused: Set(100...105))

        guard case let .unresolved(result) = await node.client().reconcile(pending()) else {
            Issue.record("expected unresolved")
            return
        }

        #expect(result.isPastValidity)
    }

    @Test func aPrunedBlockKeepsItUnknownAndKeepsTheCursor() async {
        let node = chainNode(refused: [103])

        guard case let .unresolved(result) = await node.client().reconcile(pending()) else {
            Issue.record("expected unresolved")
            return
        }

        #expect(result.isPastValidity)
    }

    @Test func aBrokenHashLinkKeepsItUnknown() async {
        let node = chainNode(tamper: { slot, block in
            if slot == 103 {
                block["previousBlockhash"] = "elsewhere"
            }
        })

        #expect(isUnresolved(await node.client().reconcile(pending())))
    }

    @Test func aHeightGapKeepsItUnknown() async {
        let node = chainNode(tamper: { slot, block in
            if slot == 103 {
                block["blockHeight"] = 1_010
            }
        })

        #expect(isUnresolved(await node.client().reconcile(pending())))
    }

    @Test func aMissingStartBlockKeepsItUnknown() async {
        var submission = pending()
        submission = SolanaPendingSubmission(
            action: submission.action,
            lastValidBlockHeight: submission.lastValidBlockHeight,
            recentBlockhash: "not-on-the-chain",
            signature: submission.signature,
            slotAtBuild: submission.slotAtBuild
        )

        #expect(isUnresolved(await chainNode().client().reconcile(submission)))
    }

    @Test func aSignatureFoundInTheWalkResolvesThroughItsTransaction() async {
        let node = chainNode(landedSlot: 103)
        node.on("getTransaction", result: #"{"meta":{"err":null},"slot":103}"#)
        #expect(await node.client().reconcile(pending()) == .confirmed)

        node.on("getTransaction", result: #"{"meta":{"err":{"InstructionError":[0,"Custom"]}},"slot":103}"#)
        #expect(await node.client().reconcile(pending()) == .failed)
    }

    @Test func aSignatureFoundButUnreadableStaysUnresolved() async {
        let node = chainNode(landedSlot: 103)
        node.on("getTransaction") { _ in nil }

        #expect(isUnresolved(await node.client().reconcile(pending())))
    }

    @Test func aRefusedStatusStaysUnresolved() async {
        let node = FakeSolanaNode()
        #expect(isUnresolved(await node.client().reconcile(pending())))
    }

    @Test func theWalkResumesFromItsCursor() async {
        let node = chainNode()
        let cursor = SolanaPendingSubmission.ExpiryCursor(blockhash: "H103", height: 1_003, slot: 103)

        #expect(await node.client().reconcile(pending(cursor: cursor)) == .expired)
        // Only 104 and 105: the start search and earlier blocks aren't read again.
        #expect(node.count("getBlock") == 2)
    }

    @Test func aFailedWalkKeepsItsProgressAndResumes() async {
        guard case let .unresolved(result) = await chainNode(refused: [103]).client().reconcile(pending()) else {
            Issue.record("expected unresolved")
            return
        }

        #expect(result.cursor?.height == 1_002)

        let node = chainNode()
        #expect(await node.client().reconcile(result) == .expired)
        #expect(node.count("getBlock") == 3)
    }

    /// A restart right after persisting: no cursor yet, only the stored `recentBlockhash`.
    @Test func aRestartWithNoCursorStartsFromTheStoredBlockhash() async throws {
        let stored = try JSONDecoder().decode(
            SolanaPendingSubmission.self,
            from: try JSONEncoder().encode(pending())
        )

        #expect(stored.cursor == nil)
        #expect(stored.recentBlockhash == "H100")
        #expect(await chainNode().client().reconcile(stored) == .expired)
    }

    @Test func progressIsCheckpointed() async {
        final class Seen: @unchecked Sendable {
            let lock = NSLock()
            var cursors: [SolanaPendingSubmission.ExpiryCursor] = []
        }

        let seen = Seen()

        _ = await chainNode().client().reconcile(pending()) { progress in
            if let cursor = progress.cursor {
                seen.lock.withLock { seen.cursors.append(cursor) }
            }
        }

        #expect(seen.lock.withLock { seen.cursors.first?.blockhash } == "H100")
    }
}
