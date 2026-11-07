import BigInt
import Foundation
import WalletKitRust

/// Seconds a built transaction stays valid after the current tip.
private let transactionLifetimeSlots: UInt64 = 7_200
/// Confirmations the tip must be past before an unseen transaction can be called expired.
private let expiryDepth: UInt64 = 15
private let poolCacheLifetime: TimeInterval = 24 * 60 * 60
private let epochsPerYear = 73.0

// MARK: - Reads

extension CardanoClient {
    /// The account's registration, delegation, rewards and epoch timing.
    ///
    /// A 404 means a never-used stake address: unregistered, no rewards.
    public func stakingRead(_ owner: CardanoAccountDescriptor) async throws -> CardanoStakingRead {
        async let epoch = epochTiming()
        let account: StakeAccount?

        do {
            account = try await get("accounts/\(owner.stakeAddress)")
        } catch HTTPError.notFound {
            account = nil
        }

        let timing = try await epoch
        guard let account else {
            return CardanoStakingRead(
                controlled: 0,
                drep: nil,
                epoch: timing,
                latestReward: nil,
                poolId: nil,
                refundDeposit: nil,
                registered: false,
                rewardsSum: 0,
                withdrawable: 0
            )
        }

        let refundDeposit = account.registered ? await latestDeposit(owner) : nil
        let reward = await latestReward(owner)

        return CardanoStakingRead(
            controlled: BigUInt(account.controlledAmount) ?? 0,
            drep: CardanoDRep(blockfrostId: account.drepId),
            epoch: timing,
            latestReward: reward,
            poolId: account.poolId,
            refundDeposit: refundDeposit,
            registered: account.registered,
            rewardsSum: BigUInt(account.rewardsSum) ?? 0,
            withdrawable: BigUInt(account.withdrawableAmount) ?? 0
        )
    }

    /// The deposit the latest registration paid. `nil` when it can't be read.
    private func latestDeposit(_ owner: CardanoAccountDescriptor) async -> UInt64? {
        let rows: [Registration]? = try? await get(
            "accounts/\(owner.stakeAddress)/registrations",
            query: [URLQueryItem(name: "order", value: "desc"), URLQueryItem(name: "count", value: "10")]
        )

        return rows?.first { $0.action == "registered" }?.deposit.flatMap { UInt64($0) }
    }

    /// The newest reward Blockfrost recorded, `nil` when none or unreadable.
    private func latestReward(_ owner: CardanoAccountDescriptor) async -> CardanoReward? {
        let rows: [Reward]? = try? await get(
            "accounts/\(owner.stakeAddress)/rewards",
            query: [URLQueryItem(name: "order", value: "desc"), URLQueryItem(name: "count", value: "1")]
        )

        return rows?.first.flatMap { row in
            UInt64(row.amount).map { CardanoReward(amount: $0, epoch: row.epoch) }
        }
    }

    /// Lovelace in the UTxOs the account can sign for: what a staking transaction may spend.
    public func signableLovelace(_ owner: CardanoAccountDescriptor) async throws -> BigUInt {
        try await spendableUTxOs(owner).utxos.reduce(into: BigUInt(0)) { total, utxo in
            total += BigUInt(utxo.lovelace) ?? 0
        }
    }

    func epochTiming() async throws -> CardanoEpochTiming {
        let epoch: Epoch = try await get("epochs/latest")
        return CardanoEpochTiming(endTime: Date(timeIntervalSince1970: TimeInterval(epoch.endTime)), epoch: epoch.epoch)
    }

    /// The pools the picker offers, cached for 24 hours per endpoint. Retiring and
    /// retired pools are filtered out; the best-ranked come first.
    public func pools(forceRefresh: Bool = false) async throws -> [CardanoPool] {
        let key = endpoint.absoluteString

        if !forceRefresh, let cached = await CardanoPoolCache.shared.pools(for: key) {
            return cached
        }

        async let listed: [ExtendedPool] = pagedPools()
        async let retiring: Set<String> = poolIds("pools/retiring")
        async let retired: Set<String> = poolIds("pools/retired")
        let excluded = try await retiring.union(retired)

        let pools = try await listed
            .filter { !excluded.contains($0.poolId) }
            .map(\.pool)
            .sorted { lhs, rhs in
                if (lhs.saturation < 1) != (rhs.saturation < 1) {
                    return lhs.saturation < 1
                }

                return (lhs.ticker != nil ? 0 : 1, lhs.poolId) < (rhs.ticker != nil ? 0 : 1, rhs.poolId)
            }

        await CardanoPoolCache.shared.store(pools, for: key)
        return pools
    }

    /// One pool with its metadata, or `nil` when it doesn't exist, has retired, or is retiring.
    public func pool(_ poolId: String) async throws -> CardanoPool? {
        let detail: PoolDetail

        do {
            detail = try await get("pools/\(poolId)")
        } catch HTTPError.notFound {
            return nil
        }

        let updates: [PoolUpdate]? = try? await get(
            "pools/\(poolId)/updates",
            query: [URLQueryItem(name: "order", value: "desc"), URLQueryItem(name: "count", value: "1")]
        )

        if updates?.first?.action == "deregistered" || !detail.retirement.isEmpty && updates == nil {
            return nil
        }

        let metadata: PoolMetadata? = try? await get("pools/\(poolId)/metadata")

        return CardanoPool(
            fixedCost: UInt64(detail.fixedCost) ?? 0,
            marginCost: detail.marginCost,
            name: metadata?.name,
            poolId: detail.poolId,
            saturation: detail.liveSaturation,
            ticker: metadata?.ticker
        )
    }

    /// Best-effort annualised return over the pool's last six epochs, after its fees.
    public func estimatedReturn(_ poolId: String) async -> Double? {
        let history: [PoolEpoch]? = try? await get(
            "pools/\(poolId)/history",
            query: [URLQueryItem(name: "order", value: "desc"), URLQueryItem(name: "count", value: "6")]
        )

        guard let history, !history.isEmpty else {
            return nil
        }

        let returns = history.compactMap { epoch -> Double? in
            guard
                let stake = Double(epoch.activeStake), stake > 0,
                let rewards = Double(epoch.rewards), let fees = Double(epoch.fees)
            else {
                return nil
            }

            return (rewards - fees) / stake
        }

        guard !returns.isEmpty else {
            return nil
        }

        return returns.reduce(0, +) / Double(returns.count) * epochsPerYear
    }

    /// A registered, non-retired DRep with its published name, or `nil`.
    public func drep(_ drepId: String) async throws -> CardanoDRepInfo? {
        let detail: DRepDetail

        do {
            detail = try await get("governance/dreps/\(drepId)")
        } catch HTTPError.notFound {
            return nil
        }

        let metadata: [String: Any]? = await drepMetadata(drepId)
        let name = metadata.flatMap(Self.givenName)

        return CardanoDRepInfo(drepId: detail.drepId, isActive: detail.active && !detail.retired, name: name)
    }

    private func drepMetadata(_ drepId: String) async -> [String: Any]? {
        guard let data = try? await rawData("governance/dreps/\(drepId)/metadata") else {
            return nil
        }

        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    /// CIP-119 `givenName`, which is a plain string or a JSON-LD `{"@value": …}`.
    static func givenName(_ metadata: [String: Any]) -> String? {
        guard let json = metadata["json_metadata"] as? [String: Any] else {
            return nil
        }

        let body = (json["body"] as? [String: Any]) ?? json

        switch body["givenName"] {
        case let name as String: return name
        case let object as [String: Any]: return object["@value"] as? String
        default: return nil
        }
    }

    private func pagedPools() async throws -> [ExtendedPool] {
        let count = 100
        var result: [ExtendedPool] = []
        var page = 1

        while true {
            let rows: [ExtendedPool] = try await get(
                "pools/extended",
                query: [URLQueryItem(name: "count", value: "\(count)"), URLQueryItem(name: "page", value: "\(page)")]
            )

            result.append(contentsOf: rows)

            guard rows.count == count else {
                return result
            }

            page += 1
        }
    }

    private func poolIds(_ path: String) async throws -> Set<String> {
        let count = 100
        var result: Set<String> = []
        var page = 1

        while true {
            let rows: [RetiringPool] = try await get(
                path,
                query: [URLQueryItem(name: "count", value: "\(count)"), URLQueryItem(name: "page", value: "\(page)")]
            )

            result.formUnion(rows.map(\.poolId))

            guard rows.count == count else {
                return result
            }

            page += 1
        }
    }

    private func rawData(_ path: String) async throws -> Data {
        guard let projectId, !projectId.isEmpty else {
            throw WalletKitError.internalError(message: "Set a Blockfrost project ID before using Cardano.")
        }

        return try await responseData(url: endpoint.appending(path: path), path: path, projectId: projectId)
    }
}

// MARK: - Building

extension CardanoClient {
    /// Builds `action` into an unsigned transaction from the account's signable UTxOs.
    ///
    /// Funding is validated only by the build; a shortfall throws
    /// ``CardanoStakingError/notEnoughADA(shortfall:)``.
    public func prepareStaking(
        _ owner: CardanoAccountDescriptor,
        action: CardanoStakingAction,
        read: CardanoStakingRead
    ) async throws -> CardanoPreparedStaking {
        let parameters: ProtocolParameters = try await get("epochs/latest/parameters")
        let (certificates, withdrawal) = try Self.parts(of: action, read: read, keyDeposit: parameters.keyDeposit)
        let (utxos, pathsByInput) = try await spendableUTxOs(owner)
        let tip = try await latestTip()

        let result = try remappingWalletKitError {
            try cardanoBuildStaking(
                certificates: certificates,
                changeAddress: owner.receiveAddress.string,
                protocolParameters: parameters.ffi,
                stakeAddress: owner.stakeAddress,
                ttl: tip.slot + transactionLifetimeSlots,
                utxos: utxos,
                withdrawal: withdrawal.map { String($0) }
            )
        }

        switch result {
        case let .insufficientFunds(shortfall):
            throw CardanoStakingError.notEnoughADA(shortfall: BigUInt(shortfall) ?? 0)
        case let .built(transaction):
            var unsigned = transaction.unsigned
            let inputPaths = try CardanoInputPaths.signingPaths(of: unsigned.inputs, pathsByInput: pathsByInput)
            unsigned.signingPaths = inputPaths + unsigned.signingPaths.filter { !inputPaths.contains($0) }

            let summary = CardanoStakingSummary(
                deposit: transaction.deposit,
                refund: transaction.refund,
                withdrawal: transaction.withdrawal
            )

            return CardanoPreparedStaking(
                deposit: BigUInt(transaction.deposit) ?? 0,
                netLovelace: BigInt(transaction.netLovelace) ?? 0,
                refund: BigUInt(transaction.refund) ?? 0,
                unsigned: CardanoUnsignedTransaction(unsigned, staking: summary),
                withdrawal: BigUInt(transaction.withdrawal) ?? 0
            )
        }
    }

    /// The ordered certificates and optional full withdrawal an action needs.
    static func parts(
        of action: CardanoStakingAction,
        read: CardanoStakingRead,
        keyDeposit: UInt64
    ) throws -> (certificates: [CardanoStakingCertificateFfi], withdrawal: UInt64?) {
        let withdrawable = UInt64(exactly: read.withdrawable)

        switch action {
        case let .stake(pool, drep):
            guard !read.registered else {
                throw WalletKitError.signingFailed(reason: "The stake key is already registered.")
            }

            var certificates: [CardanoStakingCertificateFfi] = [
                .registration(deposit: String(keyDeposit)),
                .delegation(poolId: pool)
            ]

            if let drep {
                certificates.append(.voteDelegation(drep: drep.ffi))
            }

            return (certificates, nil)
        case let .changePool(pool):
            guard read.registered else {
                throw CardanoStakingError.unregistered
            }

            return ([.delegation(poolId: pool)], nil)
        case let .changeDRep(drep):
            guard read.registered else {
                throw CardanoStakingError.unregistered
            }

            return ([.voteDelegation(drep: drep.ffi)], nil)
        case .withdraw:
            guard read.registered else {
                throw CardanoStakingError.unregistered
            }

            guard let withdrawable, withdrawable > 0 else {
                throw WalletKitError.signingFailed(reason: "There are no rewards to withdraw.")
            }

            return ([], withdrawable)
        case .stopStaking:
            guard read.registered else {
                throw CardanoStakingError.unregistered
            }

            guard let refund = read.refundDeposit else {
                throw CardanoStakingError.missingRefund
            }

            return ([.deregistration(refund: String(refund))], withdrawable.flatMap { $0 > 0 ? $0 : nil })
        }
    }

    /// Whether `action` needs a DRep delegated first: withdrawals require one.
    public static func needsDRep(_ action: CardanoStakingAction, read: CardanoStakingRead) -> Bool {
        switch action {
        case .withdraw: read.drep == nil
        case .stopStaking: read.drep == nil && read.withdrawable > 0
        default: false
        }
    }
}

// MARK: - Submission state

extension CardanoClient {
    /// The chain tip's height and slot.
    public func latestTip() async throws -> (height: UInt64, slot: UInt64) {
        let block: Block = try await get("blocks/latest")

        guard let height = block.height, let slot = block.slot else {
            throw WalletKitError.internalError(message: "Blockfrost returned no Cardano chain tip.")
        }

        return (height, slot)
    }

    /// Whether `hash` is on chain, or can no longer land.
    ///
    /// Expired only once a block at least 15 deep has a slot past `ttl` and the
    /// transaction still hasn't been seen.
    public func submissionState(
        hash: String,
        ttl: UInt64,
        inputs: [CardanoSpentInput] = []
    ) async throws -> CardanoSubmissionState {
        do {
            let _: TransactionExists = try await get("txs/\(hash)")
            return .confirmed
        } catch HTTPError.notFound {
            // A different transaction consuming an input means it can't land, however long is left. The
            // lookup only ever adds a way to end a submission early: when it fails, the TTL still decides.
            if (try? await hasConflictingSpend(hash: hash, inputs: inputs)) == true {
                return .expired
            }

            let tip = try await latestTip()

            guard tip.height > expiryDepth else {
                return .pending
            }

            let deep: Block = try await get("blocks/\(tip.height - expiryDepth)")

            guard let slot = deep.slot, slot > ttl else {
                return .pending
            }

            // Looked again after the tip read so a landing in between isn't missed.
            do {
                let _: TransactionExists = try await get("txs/\(hash)")
                return .confirmed
            } catch HTTPError.notFound {
                return .expired
            }
        }
    }

    /// ``submissionState(hash:ttl:inputs:)`` for a stored submission.
    public func submissionState(_ pending: CardanoPendingSubmission) async throws -> CardanoSubmissionState {
        try await submissionState(hash: pending.hash, ttl: pending.ttl, inputs: pending.inputs)
    }

    /// Seconds of validity a transaction with `ttl` has left at the current tip.
    public func secondsRemaining(ttl: UInt64) async throws -> Int64 {
        Int64(ttl) - Int64(try await latestTip().slot)
    }
}

// MARK: - History labels

extension CardanoClient {
    /// A staking label for `txHash`, from the certificates and withdrawals that are `owner`'s: a payment
    /// that also withdraws or deregisters someone else's stake key isn't a staking transaction for `owner`.
    ///
    /// Blockfrost's per-transaction counts aren't relied on: they may omit vote
    /// delegations, so the CBOR is decoded for every stake-account transaction.
    func stakingMethod(txHash: String, owner: CardanoAccountDescriptor) async -> String? {
        guard
            let cbor: TransactionCBOR = try? await get("txs/\(txHash)/cbor"),
            let data = try? Data(hexString: cbor.cbor),
            let decoded = try? cardanoDecodeTransaction(transaction: data)
        else {
            return nil
        }

        // A reward address is a header byte and the 28-byte stake credential.
        let credential = (try? cardanoAddressBytes(owner.stakeAddress)).map { Data($0.dropFirst()) }

        return CardanoStakingLabel.method(
            kinds: decoded.certificates.filter { $0.subject == credential }.map(\.kind),
            hasWithdrawal: decoded.withdrawals.contains { $0.rewardAddress == owner.stakeAddress }
        )
    }
}

// MARK: - Blockfrost types

extension CardanoClient {
    struct StakeAccount: Decodable {
        let controlledAmount: String
        let drepId: String?
        let poolId: String?
        let registered: Bool
        let rewardsSum: String
        let withdrawableAmount: String

        enum CodingKeys: String, CodingKey {
            case controlledAmount = "controlled_amount"
            case drepId = "drep_id"
            case poolId = "pool_id"
            case registered
            case rewardsSum = "rewards_sum"
            case withdrawableAmount = "withdrawable_amount"
        }
    }

    struct Registration: Decodable {
        let action: String
        let deposit: String?
    }

    struct Reward: Decodable {
        let amount: String
        let epoch: UInt64
    }

    struct Epoch: Decodable {
        let endTime: Int
        let epoch: UInt64

        enum CodingKeys: String, CodingKey {
            case endTime = "end_time"
            case epoch
        }
    }

    struct ExtendedPool: Decodable {
        let fixedCost: String
        let liveSaturation: Double
        let marginCost: Double
        let metadata: PoolMetadata?
        let poolId: String

        enum CodingKeys: String, CodingKey {
            case fixedCost = "fixed_cost"
            case liveSaturation = "live_saturation"
            case marginCost = "margin_cost"
            case metadata
            case poolId = "pool_id"
        }

        var pool: CardanoPool {
            CardanoPool(
                fixedCost: UInt64(fixedCost) ?? 0,
                marginCost: marginCost,
                name: metadata?.name,
                poolId: poolId,
                saturation: liveSaturation,
                ticker: metadata?.ticker
            )
        }
    }

    struct PoolMetadata: Decodable {
        let name: String?
        let ticker: String?
    }

    struct PoolDetail: Decodable {
        let fixedCost: String
        let liveSaturation: Double
        let marginCost: Double
        let poolId: String
        let retirement: [String]

        enum CodingKeys: String, CodingKey {
            case fixedCost = "fixed_cost"
            case liveSaturation = "live_saturation"
            case marginCost = "margin_cost"
            case poolId = "pool_id"
            case retirement
        }
    }

    struct PoolUpdate: Decodable {
        let action: String
    }

    struct PoolEpoch: Decodable {
        let activeStake: String
        let fees: String
        let rewards: String

        enum CodingKeys: String, CodingKey {
            case activeStake = "active_stake"
            case fees
            case rewards
        }
    }

    struct RetiringPool: Decodable {
        let poolId: String

        enum CodingKeys: String, CodingKey {
            case poolId = "pool_id"
        }
    }

    struct DRepDetail: Decodable {
        let active: Bool
        let drepId: String
        let retired: Bool

        enum CodingKeys: String, CodingKey {
            case active
            case drepId = "drep_id"
            case retired
        }
    }

    struct TransactionExists: Decodable {
        let hash: String
    }

    struct TransactionCBOR: Decodable {
        let cbor: String
    }
}

/// Pool lists, cached per endpoint for 24 hours.
actor CardanoPoolCache {
    static let shared = CardanoPoolCache()

    private var entries: [String: (pools: [CardanoPool], date: Date)] = [:]

    func pools(for key: String) -> [CardanoPool]? {
        guard let entry = entries[key], Date().timeIntervalSince(entry.date) < poolCacheLifetime else {
            return nil
        }

        return entry.pools
    }

    func store(_ pools: [CardanoPool], for key: String) {
        entries[key] = (pools, Date())
    }
} // swiftlint:disable:this file_length
