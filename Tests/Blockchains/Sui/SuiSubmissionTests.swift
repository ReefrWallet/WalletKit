// Submission recovery: what a persisted, signed staking transaction turns
// into, decided from chain evidence only.

import Foundation
import Testing
@testable import WalletKit

private let oneSui: UInt64 = 1_000_000_000

struct SuiBroadcastPolicyTests {
    private let malformed = BlockchainClientError.rpcError(code: 3, message: "Malformed transaction: bad BCS")
    private let stateful = BlockchainClientError.rpcError(code: 3, message: "Object (0xaa, 7) is already spent")

    @Test
    func onlyAStatelessRejectionOfTheOriginalSendReleases() {
        #expect(SuiBroadcastPolicy.decision(for: malformed, isOriginalSendInThisProcess: true) == .release)
    }

    @Test
    func aStateDependentRejectionNeverReleases() {
        #expect(SuiBroadcastPolicy.decision(for: stateful, isOriginalSendInThisProcess: true) == .keepPending)

        let insufficientGas = BlockchainClientError.rpcError(code: 3, message: "Insufficient gas: balance too low")
        #expect(SuiBroadcastPolicy.decision(for: insufficientGas, isOriginalSendInThisProcess: true) == .keepPending)
    }

    @Test
    func aRebroadcastOfAPersistedSubmissionNeverReleases() {
        #expect(SuiBroadcastPolicy.decision(for: malformed, isOriginalSendInThisProcess: false) == .keepPending)
        #expect(SuiBroadcastPolicy.decision(for: stateful, isOriginalSendInThisProcess: false) == .keepPending)
    }

    @Test
    func transportAndUnknownErrorsKeepItPending() {
        let transport = BlockchainClientError.transportError(reason: "offline")
        #expect(SuiBroadcastPolicy.decision(for: transport, isOriginalSendInThisProcess: true) == .keepPending)
        let unknown = SuiBroadcastPolicy.decision(for: CancellationError(), isOriginalSendInThisProcess: true)
        #expect(unknown == .keepPending)
    }
}

struct SuiSubmissionResolverTests {
    private static let alreadySpent = BlockchainClientError.rpcError(
        code: 3, message: "Object (0xaa, 7) is already spent"
    )

    private let owner: SuiAddress
    private let chain = FakeSuiChain()
    private let gasCoin: SuiObjectReference
    private let second = SuiCoinObject(
        reference: SuiObjectReference(
            objectId: Data(repeating: 0xAC, count: 32), version: 3, digest: Data(repeating: 0xAD, count: 32)
        ),
        balance: 3 * 1_000_000_000
    )

    init() throws {
        owner = try SuiAddress(rawBytes: Data(repeating: 0x11, count: 32))
        gasCoin = SuiObjectReference(
            objectId: Data(repeating: 0xAA, count: 32), version: 7, digest: Data(repeating: 0xA1, count: 32)
        )
    }

    /// A signed stake prepared against the scripted chain, at epoch 100 (so valid through epoch 101).
    private func submission() async throws -> SuiPendingSubmission {
        await chain.set(coins: [SuiCoinObject(reference: gasCoin, balance: 10 * oneSui)])
        let validator = try SuiAddress(rawBytes: Data(repeating: 0x22, count: 32))
        let prepared = try await SuiStakingPreparation(chain: chain)
            .prepare(.stake(validator: validator, amount: 5 * oneSui), owner: owner)
        return SuiPendingSubmission(
            prepared: prepared, signature: Data([1, 2, 3]), createdAt: Date(timeIntervalSince1970: 0)
        )
    }

    private func epoch(_ epoch: UInt64, lowest: UInt64 = 0, chainId: String = "chain") async {
        await chain.set(
            info: SuiServiceInfo(
                chainId: chainId, epoch: epoch, checkpointHeight: 9000, lowestAvailableCheckpoint: lowest
            )
        )
    }

    private var resolver: SuiSubmissionResolver { SuiSubmissionResolver(chain: chain) }

    @Test
    func aFinalizedTransactionIsDecidedByItsEffects() async throws {
        let pending = try await submission()

        await chain.set(status: .finalized(failure: nil))
        #expect(await resolver.resolve(pending) == .succeeded)

        await chain.set(status: .finalized(failure: "InsufficientCoinBalance"))
        #expect(await resolver.resolve(pending) == .failed("InsufficientCoinBalance"))
    }

    @Test
    func aMissingTransactionStaysUnresolvedWhileItCanStillExecute() async throws {
        let pending = try await submission()
        await epoch(100)
        #expect(await resolver.resolve(pending) == .unresolved(.stillValid))
        await epoch(101)
        #expect(await resolver.resolve(pending) == .unresolved(.stillValid))
    }

    @Test
    func expiryWithUntouchedInputsProvesItNeverRan() async throws {
        let pending = try await submission()
        await epoch(102)
        await chain.set(live: [gasCoin.objectId.hexEncoded: gasCoin])

        #expect(await resolver.resolve(pending) == .notExecuted(.inputsUntouched))
    }

    @Test
    func aSpentInputIsOnlyProofWhenAnotherFinalizedTransactionConsumedIt() async throws {
        let pending = try await submission()
        await epoch(102)
        let moved = SuiObjectReference(objectId: gasCoin.objectId, version: 9, digest: Data(repeating: 0xA9, count: 32))
        await chain.set(live: [gasCoin.objectId.hexEncoded: moved])

        await chain.set(consuming: [:])
        #expect(await resolver.resolve(pending) == .unresolved(.expiredWithoutProof))

        await chain.set(consuming: [gasCoin.objectId.hexEncoded: "OtherDigest"])
        #expect(await resolver.resolve(pending) == .notExecuted(.inputSpentElsewhere(by: "OtherDigest")))

        // The "consumer" being this very transaction would mean it ran; that is not a proof of absence.
        await chain.set(consuming: [gasCoin.objectId.hexEncoded: pending.digest])
        #expect(await resolver.resolve(pending) == .unresolved(.expiredWithoutProof))
    }

    @Test
    func aDeletedInputCountsAsChanged() async throws {
        let pending = try await submission()
        await epoch(102)
        await chain.set(live: [gasCoin.objectId.hexEncoded: nil])
        await chain.set(consuming: [gasCoin.objectId.hexEncoded: "OtherDigest"])

        #expect(await resolver.resolve(pending) == .notExecuted(.inputSpentElsewhere(by: "OtherDigest")))
    }

    /// A competing transaction merged several gas coins: one is deleted (no consumer can be found from the live
    /// object), another is live at a newer version with finalized effects that prove the conflict.
    @Test
    func aDeletedInputDoesNotHideAnotherInputsProof() async throws {
        await chain.set(coins: [SuiCoinObject(reference: gasCoin, balance: 3 * oneSui), second])
        let validator = try SuiAddress(rawBytes: Data(repeating: 0x22, count: 32))
        let prepared = try await SuiStakingPreparation(chain: chain)
            .prepare(.stake(validator: validator, amount: 5 * oneSui), owner: owner)
        let pending = SuiPendingSubmission(prepared: prepared, signature: Data([1]), createdAt: Date())
        #expect(pending.inputs.count == 2)

        await epoch(102)
        let moved = SuiObjectReference(
            objectId: second.reference.objectId, version: 12, digest: Data(repeating: 0xEE, count: 32)
        )

        await chain.set(live: [gasCoin.objectId.hexEncoded: nil, second.reference.objectId.hexEncoded: moved])
        await chain.set(consumingErrors: [gasCoin.objectId.hexEncoded])
        await chain.set(consuming: [second.reference.objectId.hexEncoded: "MergeDigest"])

        #expect(await resolver.resolve(pending) == .notExecuted(.inputSpentElsewhere(by: "MergeDigest")))
    }

    @Test
    func failedLookupsOnEveryChangedInputLeaveItUnresolvedAndRetryable() async throws {
        let pending = try await submission()
        await epoch(102)
        await chain.set(live: [gasCoin.objectId.hexEncoded: nil])
        await chain.set(consumingErrors: [gasCoin.objectId.hexEncoded])

        #expect(await resolver.resolve(pending) == .unresolved(.nodeUnavailable))
    }

    @Test
    func aNodeThatForgotTheHistoryCannotProveAbsence() async throws {
        let pending = try await submission()
        await epoch(102, lowest: pending.startCheckpoint + 1)
        await chain.set(live: [gasCoin.objectId.hexEncoded: gasCoin])

        #expect(await resolver.resolve(pending) == .unresolved(.historyPruned))
    }

    @Test
    func aDifferentChainIsNeverTrusted() async throws {
        let pending = try await submission()
        await epoch(102, chainId: "other")
        await chain.set(status: .finalized(failure: nil))

        #expect(await resolver.resolve(pending) == .unresolved(.chainMismatch))
    }

    @Test
    func anUnreachableNodeDecidesNothing() async throws {
        let pending = try await submission()
        await chain.set(infoError: BlockchainClientError.transportError(reason: "offline"))

        #expect(await resolver.resolve(pending) == .unresolved(.nodeUnavailable))
    }

    /// The first send reached the node and executed, but the app quit before it saw the answer. On relaunch the
    /// retry is rejected as "already spent"; that rejection must not release the submission, and the effects
    /// must resolve it as a success.
    @Test
    func aRetryRejectedAsAlreadySpentAfterAnUnrecordedSuccessResolvesAsSucceeded() async throws {
        let pending = try await submission()
        await chain.set(broadcastError: Self.alreadySpent)

        let result = await resolver.broadcast(pending, isOriginalSendInThisProcess: false)
        #expect(result == .keepPending)

        await chain.set(status: .finalized(failure: nil))
        #expect(await resolver.resolve(pending) == .succeeded)
    }

    /// The sibling case: the first send never executed, and the retry is rejected for the same reason because
    /// the gas coin moved on; only the expiry proof can resolve it.
    @Test
    func aRetryRejectedAfterTheFirstSendNeverExecutedResolvesViaTheExpiryProof() async throws {
        let pending = try await submission()
        await chain.set(broadcastError: Self.alreadySpent)
        #expect(await resolver.broadcast(pending, isOriginalSendInThisProcess: false) == .keepPending)

        await epoch(102)
        let moved = SuiObjectReference(objectId: gasCoin.objectId, version: 9, digest: Data(repeating: 0xA9, count: 32))
        await chain.set(live: [gasCoin.objectId.hexEncoded: moved])
        await chain.set(consuming: [gasCoin.objectId.hexEncoded: "OtherDigest"])

        #expect(await resolver.resolve(pending) == .notExecuted(.inputSpentElsewhere(by: "OtherDigest")))
    }

    @Test
    func aBroadcastIsAcceptedOnlyWhenTheNodeReportsTheSameDigest() async throws {
        let pending = try await submission()

        await chain.set(broadcastDigest: pending.digest)
        #expect(await resolver.broadcast(pending, isOriginalSendInThisProcess: true) == .accepted)

        await chain.set(broadcastDigest: "SomethingElse")
        #expect(await resolver.broadcast(pending, isOriginalSendInThisProcess: true) == .keepPending)
    }

    @Test
    func neverSendsToAnEndpointOnAnotherChainOrOneThatCannotBeVerified() async throws {
        let pending = try await submission()
        await chain.set(broadcastDigest: pending.digest)

        await epoch(101, chainId: "other")
        #expect(await resolver.broadcast(pending, isOriginalSendInThisProcess: true) == .chainMismatch)
        #expect(await resolver.broadcast(pending, isOriginalSendInThisProcess: false) == .chainMismatch)

        await chain.set(infoError: BlockchainClientError.transportError(reason: "offline"))
        #expect(await resolver.broadcast(pending, isOriginalSendInThisProcess: false) == .keepPending)

        // A verification failure that looks like a stateless rejection is still not a rejection of the
        // transaction: nothing was sent, so the release policy must not apply.
        await chain.set(infoError: BlockchainClientError.rpcError(code: 3, message: "Malformed request"))
        #expect(await resolver.broadcast(pending, isOriginalSendInThisProcess: true) == .keepPending)

        #expect(await chain.broadcastCount == 0, "nothing may reach an unverified or foreign chain")

        await chain.set(infoError: nil)
        await epoch(101)
        #expect(await resolver.broadcast(pending, isOriginalSendInThisProcess: true) == .accepted)
        #expect(await chain.broadcastCount == 1)
    }

    @Test
    func aStatelessRejectionOfTheOriginalSendReleasesTheSubmission() async throws {
        let pending = try await submission()
        await chain.set(broadcastError: BlockchainClientError.rpcError(code: 3, message: "Malformed transaction"))

        #expect(await resolver.broadcast(pending, isOriginalSendInThisProcess: true) == .released)
    }

    @Test
    func aSubmissionRoundTripsThroughStorage() async throws {
        let pending = try await submission()
        let decoded = try JSONDecoder().decode(SuiPendingSubmission.self, from: JSONEncoder().encode(pending))
        #expect(decoded == pending)
        let digest = SuiProgrammableTransaction.digest(ofTransactionData: decoded.transactionData)
        #expect(decoded.digest == Base58.encode(digest))
    }
}
