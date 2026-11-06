//
//  SolanaRPCClient+Staking.swift
//  WalletKit
//
//  Created by Andrey Yurkevich on 06/11/2026.
//  Copyright © 2026 Reefr Wallet. All rights reserved.
//

import Foundation

// MARK: - Position

public extension SolanaRPCClient {
    /// Reads `owner`'s stake accounts.
    ///
    /// If `getProgramAccounts` fails for either authority, the result is built from `known`
    /// and the app's own seeds and marked degraded: it drops an address only when the read
    /// shows it closed or no longer under `owner`'s authority.
    ///
    /// - Throws: if the snapshot can't be read, or the fallback fails too.
    func stakingRead(owner: SolanaAddress, known: [String]) async throws -> SolanaStakingRead {
        let (clock, history) = try await stakingSnapshot()
        let cluster = try await clusterInfo()

        async let slotDuration = try? measuredSlotDuration()
        async let byStaker = try? stakeAccounts(authority: owner, offset: 12)
        async let byWithdrawer = try? stakeAccounts(authority: owner, offset: 44)

        let staker = await byStaker
        let withdrawer = await byWithdrawer
        let accounts: [SolanaStakeAccount]
        let discovery: SolanaStakeDiscovery

        if let staker, let withdrawer {
            accounts = Self.unique(staker + withdrawer)
            discovery = .complete
        } else {
            accounts = try await fallbackAccounts(owner: owner, known: known)
            discovery = .degraded
        }

        return SolanaStakingRead(
            accounts: accounts.sorted { $0.address < $1.address },
            clock: clock,
            discovery: discovery,
            history: history,
            newRateEpoch: cluster.newRateEpoch,
            schedule: cluster.schedule,
            slotDuration: await slotDuration
        )
    }

    /// The smallest delegation the cluster accepts, in lamports.
    func minimumDelegation() async throws -> UInt64 {
        let response: SolanaRPCValue<UInt64> = try await rpc.call(
            method: "getStakeMinimumDelegation", params: [CommitmentConfig()]
        )

        return response.value
    }

    /// The rent a new stake account must hold, in lamports.
    func stakeAccountRent() async throws -> UInt64 {
        try await minimumBalanceForRentExemption(dataLength: Int(StakeProgram.accountSize))
    }

    /// The first `stake:N` seed of `owner` whose address is free, however many are taken.
    func nextStakeSeed(owner: SolanaAddress) async throws -> (seed: String, address: SolanaAddress) {
        var start = 0

        while true {
            let page = try Self.seedPage(owner: owner, start: start)
            let found = try await multipleAccounts(page.map(\.address.string))

            if let index = found.firstIndex(where: { $0 == nil }) {
                return page[index]
            }

            start += page.count
        }
    }
}

// MARK: - Rewards

public extension SolanaRPCClient {
    /// `read`'s previous epoch's rewards for its accounts and `retired`, addresses that left the
    /// position. A `null` result counts as earning nothing only with proof from `read`'s history.
    ///
    /// - Returns: `nil` if there is nothing to ask about.
    func stakingRewards(
        read: SolanaStakingRead,
        retired: [String],
        attemptedAt: Date = Date()
    ) async throws -> SolanaStakingRewards? {
        guard read.clock.epoch > 0 else {
            return nil
        }

        let epoch = read.clock.epoch - 1
        let addresses = Array(Set(read.accounts.map(\.address) + retired)).sorted()

        guard !addresses.isEmpty else {
            return nil
        }

        let results = try await inflationRewards(addresses, epoch: epoch)
        let accounts = Dictionary(read.accounts.map { ($0.address, $0) }, uniquingKeysWith: { first, _ in first })

        var lamports: UInt64 = 0
        var unknown: [String] = []

        for (address, amount) in zip(addresses, results) {
            if let amount {
                lamports += amount
            } else if !Self.provesNoRewards(accounts[address], epoch: epoch, read: read) {
                unknown.append(address)
            }
        }

        return SolanaStakingRewards(
            attemptedAt: attemptedAt,
            epoch: epoch,
            lamports: lamports,
            queriedAddresses: addresses,
            unknownAddresses: unknown
        )
    }

    /// A retired account is gone, so nothing can be proved about it.
    private static func provesNoRewards(
        _ account: SolanaStakeAccount?,
        epoch: UInt64,
        read: SolanaStakingRead
    ) -> Bool {
        guard let account else {
            return false
        }

        guard let delegation = account.delegation else {
            return true
        }

        return delegation.provesNoEffectiveStake(in: epoch, history: read.history, newRateEpoch: read.newRateEpoch)
    }
}

// MARK: - Validators

public extension SolanaRPCClient {
    /// Votable validators, best first. Names and rates come from the indexer; without it
    /// (or if it fails) the node's own list is used, which has neither.
    func validators() async throws -> [SolanaValidator] {
        if let indexed = try? await indexedValidators(), !indexed.isEmpty {
            return indexed
        }

        let response: VoteAccounts = try await rpc.call(method: "getVoteAccounts", params: [CommitmentConfig()])
        let current = response.current.map { SolanaValidator(commission: $0.commission, voteAddress: $0.votePubkey) }
        let delinquent = response.delinquent.map {
            SolanaValidator(commission: $0.commission, isDelinquent: true, voteAddress: $0.votePubkey)
        }

        let stakes = Dictionary(
            (response.current + response.delinquent).map { ($0.votePubkey, $0.activatedStake) },
            uniquingKeysWith: { first, _ in first }
        )

        return (current + delinquent).sorted { lhs, rhs in
            if lhs.commission != rhs.commission {
                return (lhs.commission ?? .max) < (rhs.commission ?? .max)
            }

            return (stakes[lhs.voteAddress] ?? 0) > (stakes[rhs.voteAddress] ?? 0)
        }
    }

    private func indexedValidators() async throws -> [SolanaValidator] {
        guard let validatorIndexEndpoint else {
            return []
        }

        let data = try await SolanaStakewiz.validators(endpoint: validatorIndexEndpoint, session: rpc.session)

        return try JSONDecoder().decode([SolanaStakewiz.Validator].self, from: data)
            .sorted { ($0.wiz_score ?? 0) > ($1.wiz_score ?? 0) }
            .map(\.validator)
    }
}

// MARK: - Building

public extension SolanaRPCClient {
    /// Builds and simulates `action`, sized to the compute units it uses. Nothing is signed.
    ///
    /// - Throws: ``SolanaStakingBuildError`` if it doesn't fit or simulation rejects it.
    func prepareStaking(_ action: SolanaStakingAction, owner: SolanaAddress) async throws -> SolanaPreparedStaking {
        let context = try await blockhashWithContext()
        let price = try await recentPrioritizationFee()
        let needsAccount: Bool

        switch action {
        case .stake, .unstakePartial: needsAccount = true
        case .unstake, .withdraw: needsAccount = false
        }

        let rent = needsAccount ? try await stakeAccountRent() : 0
        let created = needsAccount ? try await nextStakeSeed(owner: owner) : nil

        let instructions = try SolanaStakingTransactions.instructions(
            for: action, owner: owner, created: created, rent: rent
        )

        func compile(limit: UInt32) throws -> SolanaMessage {
            try SolanaMessage.compile(
                payer: owner,
                instructions: [
                    ComputeBudgetProgram.setComputeUnitPrice(microLamports: price),
                    ComputeBudgetProgram.setComputeUnitLimit(limit)
                ] + instructions,
                recentBlockhash: context.blockhash
            )
        }

        let probe = try compile(limit: SolanaStakingTransactions.maxComputeUnits).serialize()

        guard SolanaStakingTransactions.fits(message: probe) else {
            throw SolanaStakingBuildError.transactionTooLarge
        }

        let units = try await simulatedUnits(message: probe)
        let message = try compile(limit: SolanaStakingTransactions.computeUnitLimit(simulated: units)).serialize()
        let unsigned = try JSONEncoder().encode(SolanaUnsignedTransaction(message: message))

        return SolanaPreparedStaking(
            action: action,
            estimate: try await estimateFee(transaction: unsigned),
            lastValidBlockHeight: context.lastValidBlockHeight,
            recentBlockhash: Base58.encode(context.blockhash),
            rent: rent,
            slotAtBuild: context.slot,
            unsigned: unsigned
        )
    }
}

/// Pure transaction assembly, shared with ``SolanaRPCClient/prepareStaking(_:owner:)``.
public enum SolanaStakingTransactions {
    static let maxComputeUnits: UInt32 = 1_400_000
    /// A transaction's limit on the wire: signature count, signatures and message.
    public static let maxTransactionSize = 1_232
    /// The signature count prefix and this wallet's one signature.
    static let signatureOverhead = 65

    /// Whether a transaction with this serialized message fits on the wire.
    public static func fits(message: Data) -> Bool {
        message.count + signatureOverhead <= maxTransactionSize
    }

    static func computeUnitLimit(simulated units: UInt64) -> UInt32 {
        UInt32(min(units + units / 5 + 1_000, UInt64(maxComputeUnits)))
    }

    /// How many of `addresses` a whole-account unstake (`deactivate`) or withdrawal fits,
    /// measured from the complete message with its compute-budget instructions.
    public static func selectionLimit(
        owner: SolanaAddress,
        addresses: [SolanaAddress],
        isWithdrawal: Bool
    ) throws -> Int {
        var count = 0

        while count < addresses.count {
            let instructions = addresses.prefix(count + 1).map { address in
                isWithdrawal
                    ? StakeProgram.withdraw(stake: address, recipient: owner, withdrawer: owner, lamports: .max)
                    : StakeProgram.deactivate(stake: address, staker: owner)
            }

            let message = try SolanaMessage.compile(
                payer: owner,
                instructions: [
                    ComputeBudgetProgram.setComputeUnitPrice(microLamports: .max),
                    ComputeBudgetProgram.setComputeUnitLimit(maxComputeUnits)
                ] + instructions,
                recentBlockhash: Data(count: 32)
            )

            guard fits(message: message.serialize()) else {
                break
            }

            count += 1
        }

        return count
    }

    static func instructions(
        for action: SolanaStakingAction,
        owner: SolanaAddress,
        created: (seed: String, address: SolanaAddress)?,
        rent: UInt64
    ) throws -> [SolanaInstruction] {
        switch action {
        case let .stake(lamports, voter):
            let created = try require(created)

            return [
                SystemProgram.createAccountWithSeed(
                    funder: owner,
                    created: created.address,
                    seed: created.seed,
                    lamports: lamports + rent,
                    space: StakeProgram.accountSize,
                    owner: SolanaProgram.stake
                ),
                StakeProgram.initialize(stake: created.address, authority: owner),
                StakeProgram.delegate(stake: created.address, voter: try SolanaAddress(string: voter), staker: owner)
            ]

        case let .unstake(accounts):
            return try accounts.map { StakeProgram.deactivate(stake: try SolanaAddress(string: $0), staker: owner) }

        case let .unstakePartial(account, lamports):
            let created = try require(created)

            return [
                SystemProgram.createAccountWithSeed(
                    funder: owner,
                    created: created.address,
                    seed: created.seed,
                    lamports: rent,
                    space: StakeProgram.accountSize,
                    owner: SolanaProgram.stake
                ),
                StakeProgram.split(
                    source: try SolanaAddress(string: account),
                    destination: created.address,
                    staker: owner,
                    lamports: lamports
                ),
                StakeProgram.deactivate(stake: created.address, staker: owner)
            ]

        case let .withdraw(withdrawals):
            return try withdrawals.map {
                StakeProgram.withdraw(
                    stake: try SolanaAddress(string: $0.address),
                    recipient: owner,
                    withdrawer: owner,
                    lamports: $0.lamports
                )
            }
        }
    }

    private static func require<T>(_ value: T?) throws -> T {
        guard let value else {
            throw WalletKitError.internalError(message: "This Solana staking action needs a new stake account.")
        }

        return value
    }
}

// MARK: - Confirmation

public extension SolanaRPCClient {
    /// The Base58 signature of `signature`, which is also the transaction id.
    static func signatureString(_ signature: Data) -> String {
        Base58.encode(signature)
    }

    func signatureStatus(_ signature: String, searchHistory: Bool) async throws -> SolanaSignatureStatus {
        let response: SolanaRPCValue<[SignatureStatusEntry?]> = try await rpc.call(
            method: "getSignatureStatuses",
            params: SignatureStatusParams(signature: signature, searchHistory: searchHistory)
        )

        guard let entry = response.value.first ?? nil else {
            return .notFound
        }

        switch entry.confirmationStatus {
        case "confirmed", "finalized":
            return entry.hasError ? .failed : .confirmed
        default:
            return .processed
        }
    }

    func blockHeight(commitment: SolanaCommitment) async throws -> UInt64 {
        try await rpc.call(method: "getBlockHeight", params: [Config(commitment: commitment.rawValue)])
    }

    /// Finds out what became of `pending`. Only `confirmed` or better resolves a status, and a
    /// missing status resolves nothing: expiry takes the walk in `proveExpiry(_:checkpoint:)`.
    /// Any failure leaves it unresolved.
    func reconcile(
        _ pending: SolanaPendingSubmission,
        checkpoint: @Sendable (SolanaPendingSubmission) async -> Void = { _ in }
    ) async -> SolanaSubmissionUpdate {
        var pending = pending

        do {
            switch try await signatureStatus(pending.signature, searchHistory: true) {
            case .confirmed:
                return .confirmed
            case .failed:
                return .failed
            case .processed:
                return .unresolved(pending)
            case .notFound:
                break
            }

            guard try await blockHeight(commitment: .finalized) > pending.lastValidBlockHeight else {
                return .unresolved(pending)
            }

            pending.isPastValidity = true
            return try await proveExpiry(&pending, checkpoint: checkpoint)
        } catch {
            return .unresolved(pending)
        }
    }

    /// Walks the finalized chain from the block whose hash the transaction references through
    /// the block at its last valid height. Each step must link by hash and rise by one height,
    /// so every block it could have landed in has been seen. `pending` keeps the progress
    /// when this throws.
    private func proveExpiry(
        _ pending: inout SolanaPendingSubmission,
        checkpoint: @Sendable (SolanaPendingSubmission) async -> Void
    ) async throws -> SolanaSubmissionUpdate {
        if pending.cursor == nil {
            guard let start = try await startBlock(of: pending) else {
                return .unresolved(pending)
            }

            pending.cursor = start
            await checkpoint(pending)
        }

        guard var cursor = pending.cursor else {
            return .unresolved(pending)
        }

        let finalized: UInt64 = try await rpc.call(method: "getSlot", params: [Config(commitment: "finalized")])

        while cursor.height < pending.lastValidBlockHeight {
            guard cursor.slot < finalized else {
                return .unresolved(pending)
            }

            let upper = min(cursor.slot + Self.walkPageSlots, finalized)
            let slots = try await finalizedBlocks(from: cursor.slot + 1, through: upper)

            guard !slots.isEmpty else {
                cursor = SolanaPendingSubmission.ExpiryCursor(
                    blockhash: cursor.blockhash, height: cursor.height, slot: upper
                )

                pending.cursor = cursor
                continue
            }

            for slot in slots {
                let block = try await signaturesBlock(slot: slot)

                guard block.previousBlockhash == cursor.blockhash, block.blockHeight == cursor.height + 1 else {
                    return .unresolved(pending)
                }

                if block.signatures.contains(pending.signature) {
                    return try await landedOutcome(pending)
                }

                cursor = SolanaPendingSubmission.ExpiryCursor(
                    blockhash: block.blockhash, height: block.blockHeight, slot: slot
                )

                pending.cursor = cursor

                if cursor.height >= pending.lastValidBlockHeight {
                    return .expired
                }
            }

            await checkpoint(pending)
        }

        return .expired
    }

    private func startBlock(of pending: SolanaPendingSubmission) async throws -> SolanaPendingSubmission.ExpiryCursor? {
        let lower = pending.slotAtBuild > Self.startSearchSlots ? pending.slotAtBuild - Self.startSearchSlots : 0
        let slots = try await finalizedBlocks(from: lower, through: pending.slotAtBuild + Self.startSearchSlots)

        let nearestFirst = slots.sorted {
            $0.distance(to: pending.slotAtBuild).magnitude < $1.distance(to: pending.slotAtBuild).magnitude
        }

        for slot in nearestFirst {
            let block = try await signaturesBlock(slot: slot)

            if block.blockhash == pending.recentBlockhash {
                return SolanaPendingSubmission.ExpiryCursor(
                    blockhash: block.blockhash, height: block.blockHeight, slot: slot
                )
            }
        }

        return nil
    }

    private func landedOutcome(_ pending: SolanaPendingSubmission) async throws -> SolanaSubmissionUpdate {
        let transaction: LandedTransaction? = try await rpc.call(
            method: "getTransaction",
            params: LandedTransactionParams(signature: pending.signature)
        )

        guard let transaction else {
            return .unresolved(pending)
        }

        return transaction.meta.hasError ? .failed : .confirmed
    }

    private static var walkPageSlots: UInt64 { 64 }
    private static var startSearchSlots: UInt64 { 64 }
}

// MARK: - Private reads

private extension SolanaRPCClient {
    /// Clock and StakeHistory from one node state, so a lagging node can't pair a new epoch with
    /// a history that lacks the entry the activation calculation would then assume was final.
    func stakingSnapshot() async throws -> (SolanaClock, SolanaStakeHistory) {
        let found = try await multipleAccounts([
            SolanaProgram.sysvarClock.string,
            SolanaProgram.sysvarStakeHistory.string
        ])

        guard
            found.count == 2,
            let clockData = found[0]?.data,
            let historyData = found[1]?.data,
            let clock = SolanaClock(data: clockData),
            let history = SolanaStakeHistory(data: historyData)
        else {
            throw BlockchainClientError.decodingFailed(reason: "unreadable Clock or StakeHistory sysvar")
        }

        guard clock.epoch == 0 || history.newestEpoch == clock.epoch - 1 else {
            throw BlockchainClientError.decodingFailed(
                reason: "stake history ends at \(history.newestEpoch.map(String.init) ?? "nothing") in epoch \(clock.epoch)"
            )
        }

        return (clock, history)
    }

    func clusterInfo() async throws -> SolanaClusterInfo {
        if let cached = await SolanaClusterInfoCache.shared.value(for: rpc.endpoint) {
            return cached
        }

        let schedule: EpochScheduleResponse = try await rpc.call(method: "getEpochSchedule", params: [String]())
        let result = schedule.schedule
        var newRateEpoch: UInt64?

        if let feature = try await rawAccountInfo(of: SolanaProgram.reduceStakeWarmupCooldown) {
            var reader = SolanaByteReader(feature.data.dropFirst())

            if feature.data.first == 1, let slot = reader.uint64() {
                newRateEpoch = result.epochAndIndex(of: slot).epoch
            }
        }

        let info = SolanaClusterInfo(newRateEpoch: newRateEpoch, schedule: result)

        // The rate can still change while the feature is inactive.
        if newRateEpoch != nil {
            await SolanaClusterInfoCache.shared.store(info, for: rpc.endpoint)
        }

        return info
    }

    func measuredSlotDuration() async throws -> Double? {
        let samples: [PerformanceSample] = try await rpc.call(method: "getRecentPerformanceSamples", params: [5])
        let slots = samples.reduce(0) { $0 + $1.numSlots }
        let seconds = samples.reduce(0) { $0 + $1.samplePeriodSecs }

        return slots > 0 ? Double(seconds) / Double(slots) : nil
    }

    func stakeAccounts(authority: SolanaAddress, offset: Int) async throws -> [SolanaStakeAccount] {
        let entries: [ProgramAccount] = try await rpc.call(
            method: "getProgramAccounts",
            params: ProgramAccountsParams(authority: authority.string, offset: offset)
        )

        return entries.compactMap { entry in
            guard let data = entry.account.data.first.flatMap({ Data(base64Encoded: $0) }) else {
                return nil
            }

            return SolanaStakeAccount(address: entry.pubkey, lamports: entry.account.lamports, data: data)
        }
    }

    /// Known addresses refreshed, plus hits among the app's own seeds.
    func fallbackAccounts(owner: SolanaAddress, known: [String]) async throws -> [SolanaStakeAccount] {
        var accounts = try await parsedStakeAccounts(known)
        var start = 0

        while true {
            let page = try Self.seedPage(owner: owner, start: start)
            let hits = try await parsedStakeAccounts(page.map(\.address.string))

            guard !hits.isEmpty else {
                break
            }

            accounts += hits
            start += page.count
        }

        return Self.unique(accounts).filter { $0.staker == owner.string || $0.withdrawer == owner.string }
    }

    func parsedStakeAccounts(_ addresses: [String]) async throws -> [SolanaStakeAccount] {
        let found = try await multipleAccounts(addresses)

        return zip(addresses, found).compactMap { address, account in
            guard let account, account.owner == SolanaProgram.stake.string else {
                return nil
            }

            return SolanaStakeAccount(address: address, lamports: account.lamports, data: account.data)
        }
    }

    /// `getMultipleAccounts` in pages of its limit; `nil` for each missing account.
    func multipleAccounts(_ addresses: [String]) async throws -> [RawAccount?] {
        var result: [RawAccount?] = []
        var index = 0

        while index < addresses.count {
            let page = Array(addresses[index..<min(index + Self.multipleAccountsLimit, addresses.count)])
            let response: SolanaRPCValue<[RawAccountEntry?]> = try await rpc.call(
                method: "getMultipleAccounts",
                params: MultipleAccountsParams(addresses: page)
            )

            result += response.value.map { $0?.account }
            index += page.count
        }

        return result
    }

    func inflationRewards(_ addresses: [String], epoch: UInt64) async throws -> [UInt64?] {
        var result: [UInt64?] = []
        var index = 0

        while index < addresses.count {
            let page = Array(addresses[index..<min(index + Self.multipleAccountsLimit, addresses.count)])
            let response: [InflationReward?] = try await rpc.call(
                method: "getInflationReward",
                params: InflationRewardParams(addresses: page, epoch: epoch)
            )

            result += response.map { $0?.amount }
            index += page.count
        }

        return result
    }

    func blockhashWithContext() async throws -> BlockhashContext {
        let response: ContextValue<BlockhashValue> = try await rpc.call(
            method: "getLatestBlockhash", params: [CommitmentConfig()]
        )

        let decoded = try Base58.decode(response.value.blockhash)

        guard decoded.count == 32 else {
            throw BlockchainClientError.decodingFailed(reason: "invalid blockhash: \(response.value.blockhash)")
        }

        return BlockhashContext(
            blockhash: decoded,
            lastValidBlockHeight: response.value.lastValidBlockHeight,
            slot: response.context.slot
        )
    }

    func simulatedUnits(message: Data) async throws -> UInt64 {
        var wire = SolanaShortVec.encode(1)
        wire.append(Data(count: 64))
        wire.append(message)

        let response: SolanaRPCValue<SimulationResult> = try await rpc.call(
            method: "simulateTransaction",
            params: SimulationParams(transaction: wire.base64EncodedString())
        )

        if response.value.hasError {
            if response.value.logs?.contains(where: { $0.contains("custom program error: 0x10") }) == true {
                throw SolanaStakingBuildError.epochRewardsActive
            }

            throw SolanaStakingBuildError.simulationFailed(
                response.value.logs?.last { $0.localizedCaseInsensitiveContains("error") || $0.contains("failed") }
                    ?? response.value.errorDescription
            )
        }

        return response.value.unitsConsumed ?? UInt64(SolanaStakingTransactions.maxComputeUnits)
    }

    func finalizedBlocks(from start: UInt64, through end: UInt64) async throws -> [UInt64] {
        try await rpc.call(method: "getBlocks", params: BlocksParams(start: start, end: end))
    }

    func signaturesBlock(slot: UInt64) async throws -> SignaturesBlock {
        try await rpc.call(method: "getBlock", params: BlockParams(slot: slot))
    }

    static var multipleAccountsLimit: Int { 100 }
    static var seedPageSize: Int { 32 }

    static func seedPage(owner: SolanaAddress, start: Int) throws -> [(seed: String, address: SolanaAddress)] {
        try (start..<(start + seedPageSize)).map { index in
            let seed = "stake:\(index)"
            return (seed, try SolanaAddress.createWithSeed(base: owner, seed: seed, owner: SolanaProgram.stake))
        }
    }

    static func unique(_ accounts: [SolanaStakeAccount]) -> [SolanaStakeAccount] {
        Array(Dictionary(accounts.map { ($0.address, $0) }, uniquingKeysWith: { first, _ in first }).values)
    }
}

// MARK: - Cluster info cache

private struct SolanaClusterInfo: Sendable {
    let newRateEpoch: UInt64?
    let schedule: SolanaEpochSchedule
}

/// A cluster's schedule never changes and an active feature gate stays active.
private actor SolanaClusterInfoCache {
    static let shared = SolanaClusterInfoCache()

    private var values: [URL: SolanaClusterInfo] = [:]

    func store(_ info: SolanaClusterInfo, for endpoint: URL) {
        values[endpoint] = info
    }

    func value(for endpoint: URL) -> SolanaClusterInfo? {
        values[endpoint]
    }
}

// MARK: - Wire types

private struct BlockhashContext {
    let blockhash: Data
    let lastValidBlockHeight: UInt64
    let slot: UInt64
}

private struct CommitmentConfig: Encodable {
    let commitment = "confirmed"
}

private struct Config: Encodable {
    let commitment: String
}

private struct RawAccount {
    let data: Data
    let lamports: UInt64
    let owner: String
}

private struct RawAccountEntry: Decodable {
    let account: RawAccount

    private enum CodingKeys: String, CodingKey {
        case data, lamports, owner
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let encoded = try container.decode([String].self, forKey: .data)

        guard let data = encoded.first.flatMap({ Data(base64Encoded: $0) }) else {
            throw BlockchainClientError.decodingFailed(reason: "account data isn't base64")
        }

        account = RawAccount(
            data: data,
            lamports: try container.decode(UInt64.self, forKey: .lamports),
            owner: try container.decode(String.self, forKey: .owner)
        )
    }
}

private struct MultipleAccountsParams: Encodable {
    let addresses: [String]

    private struct Options: Encodable {
        let commitment = "confirmed"
        let encoding = "base64"
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.unkeyedContainer()
        try container.encode(addresses)
        try container.encode(Options())
    }
}

private struct ProgramAccountsParams: Encodable {
    let authority: String
    let offset: Int

    private struct Memcmp: Encodable {
        let bytes: String
        let offset: Int
    }

    private struct Filter: Encodable {
        let dataSize: UInt64?
        let memcmp: Memcmp?
    }

    private struct Options: Encodable {
        let commitment = "confirmed"
        let encoding = "base64"
        let filters: [Filter]
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.unkeyedContainer()
        try container.encode(SolanaProgram.stake.string)
        try container.encode(Options(filters: [
            Filter(dataSize: StakeProgram.accountSize, memcmp: nil),
            Filter(dataSize: nil, memcmp: Memcmp(bytes: authority, offset: offset))
        ]))
    }
}

private struct ProgramAccount: Decodable {
    struct Account: Decodable {
        let data: [String]
        let lamports: UInt64
    }

    let account: Account
    let pubkey: String
}

private struct PerformanceSample: Decodable {
    let numSlots: UInt64
    let samplePeriodSecs: UInt64
}

private struct EpochScheduleResponse: Decodable {
    let firstNormalEpoch: UInt64
    let firstNormalSlot: UInt64
    let slotsPerEpoch: UInt64

    var schedule: SolanaEpochSchedule {
        SolanaEpochSchedule(
            firstNormalEpoch: firstNormalEpoch,
            firstNormalSlot: firstNormalSlot,
            slotsPerEpoch: slotsPerEpoch
        )
    }
}

private struct InflationRewardParams: Encodable {
    let addresses: [String]
    let epoch: UInt64

    private struct Options: Encodable {
        let epoch: UInt64
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.unkeyedContainer()
        try container.encode(addresses)
        try container.encode(Options(epoch: epoch))
    }
}

private struct InflationReward: Decodable {
    let amount: UInt64
}

private struct VoteAccounts: Decodable {
    struct Entry: Decodable {
        let activatedStake: UInt64
        let commission: Int
        let votePubkey: String
    }

    let current: [Entry]
    let delinquent: [Entry]
}

private struct ContextValue<Value: Decodable>: Decodable {
    struct Context: Decodable {
        let slot: UInt64
    }

    let context: Context
    let value: Value
}

private struct BlockhashValue: Decodable {
    let blockhash: String
    let lastValidBlockHeight: UInt64
}

private struct SimulationParams: Encodable {
    let transaction: String

    private struct Options: Encodable {
        let commitment = "confirmed"
        let encoding = "base64"
        let replaceRecentBlockhash = false
        let sigVerify = false
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.unkeyedContainer()
        try container.encode(transaction)
        try container.encode(Options())
    }
}

private struct SimulationResult: Decodable {
    let errorDescription: String
    let hasError: Bool
    let logs: [String]?
    let unitsConsumed: UInt64?

    private enum CodingKeys: String, CodingKey {
        case err, logs, unitsConsumed
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        hasError = try container.contains(.err) && !container.decodeNil(forKey: .err)
        errorDescription = (try? container.decode(String.self, forKey: .err)) ?? "simulation failed"
        logs = try container.decodeIfPresent([String].self, forKey: .logs)
        unitsConsumed = try container.decodeIfPresent(UInt64.self, forKey: .unitsConsumed)
    }
}

private struct SignatureStatusParams: Encodable {
    let signature: String
    let searchHistory: Bool

    private struct Options: Encodable {
        let searchTransactionHistory: Bool
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.unkeyedContainer()
        try container.encode([signature])
        try container.encode(Options(searchTransactionHistory: searchHistory))
    }
}

private struct SignatureStatusEntry: Decodable {
    let confirmationStatus: String?
    let hasError: Bool

    private enum CodingKeys: String, CodingKey {
        case confirmationStatus, err
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        confirmationStatus = try container.decodeIfPresent(String.self, forKey: .confirmationStatus)
        hasError = try container.contains(.err) && !container.decodeNil(forKey: .err)
    }
}

private struct BlocksParams: Encodable {
    let start: UInt64
    let end: UInt64

    func encode(to encoder: Encoder) throws {
        var container = encoder.unkeyedContainer()
        try container.encode(start)
        try container.encode(end)
        try container.encode(Config(commitment: "finalized"))
    }
}

private struct BlockParams: Encodable {
    let slot: UInt64

    private struct Options: Encodable {
        let commitment = "finalized"
        let encoding = "json"
        let maxSupportedTransactionVersion = 0
        let rewards = false
        let transactionDetails = "signatures"
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.unkeyedContainer()
        try container.encode(slot)
        try container.encode(Options())
    }
}

private struct SignaturesBlock: Decodable {
    let blockHeight: UInt64
    let blockhash: String
    let previousBlockhash: String
    let signatures: [String]
}

private struct LandedTransactionParams: Encodable {
    let signature: String

    private struct Options: Encodable {
        let commitment = "finalized"
        let encoding = "json"
        let maxSupportedTransactionVersion = 0
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.unkeyedContainer()
        try container.encode(signature)
        try container.encode(Options())
    }
}

private struct LandedTransaction: Decodable {
    struct Meta: Decodable {
        let hasError: Bool

        private enum CodingKeys: String, CodingKey {
            case err
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            hasError = try container.contains(.err) && !container.decodeNil(forKey: .err)
        }
    }

    let meta: Meta
} // swiftlint:disable:this file_length
