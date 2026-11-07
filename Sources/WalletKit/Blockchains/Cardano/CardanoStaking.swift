import BigInt
import Foundation
import WalletKitRust

/// The governance vote a stake key delegates to.
public enum CardanoDRep: Codable, Equatable, Hashable, Sendable {
    case abstain
    /// A CIP-129 or CIP-105 bech32 id.
    case id(String)
    case noConfidence

    var ffi: CardanoDRepFfi {
        switch self {
        case .abstain: .abstain
        case let .id(bech32): .id(bech32: bech32)
        case .noConfidence: .noConfidence
        }
    }

    /// Reads Blockfrost's `drep_id`, which spells the predefined DReps out.
    init?(blockfrostId: String?) {
        switch blockfrostId {
        case nil: return nil
        case "drep_always_abstain": self = .abstain
        case "drep_always_no_confidence": self = .noConfidence
        case let id?: self = .id(id)
        }
    }
}

/// A DRep as Blockfrost reports it.
public struct CardanoDRepInfo: Codable, Equatable, Sendable {
    public let drepId: String
    public let isActive: Bool
    public let name: String?

    public init(drepId: String, isActive: Bool, name: String?) {
        self.drepId = drepId
        self.isActive = isActive
        self.name = name
    }
}

/// A stake pool as the picker shows it.
public struct CardanoPool: Codable, Equatable, Identifiable, Sendable {
    public var id: String { poolId }

    public let fixedCost: UInt64
    public let marginCost: Double
    public let name: String?
    public let poolId: String
    public let saturation: Double
    public let ticker: String?

    public init(
        fixedCost: UInt64,
        marginCost: Double,
        name: String?,
        poolId: String,
        saturation: Double,
        ticker: String?
    ) {
        self.fixedCost = fixedCost
        self.marginCost = marginCost
        self.name = name
        self.poolId = poolId
        self.saturation = saturation
        self.ticker = ticker
    }
}

/// The latest recorded reward and the epoch it belongs to.
public struct CardanoReward: Codable, Equatable, Sendable {
    public let amount: UInt64
    public let epoch: UInt64

    public init(amount: UInt64, epoch: UInt64) {
        self.amount = amount
        self.epoch = epoch
    }
}

/// The current epoch and when it ends.
public struct CardanoEpochTiming: Codable, Equatable, Sendable {
    public let endTime: Date
    public let epoch: UInt64

    public init(endTime: Date, epoch: UInt64) {
        self.endTime = endTime
        self.epoch = epoch
    }
}

/// An account's staking state on chain.
public struct CardanoStakingRead: Codable, Equatable, Sendable {
    /// Lovelace controlled by the stake address. Display only: it can include UTxOs
    /// that other payment keys hold under the same stake key.
    public let controlled: BigUInt
    public let drep: CardanoDRep?
    public let epoch: CardanoEpochTiming
    public let latestReward: CardanoReward?
    public let poolId: String?
    /// The deposit the latest registration paid, `nil` when unregistered or unreadable.
    public let refundDeposit: UInt64?
    public let registered: Bool
    public let rewardsSum: BigUInt
    public let withdrawable: BigUInt

    public init(
        controlled: BigUInt,
        drep: CardanoDRep?,
        epoch: CardanoEpochTiming,
        latestReward: CardanoReward?,
        poolId: String?,
        refundDeposit: UInt64?,
        registered: Bool,
        rewardsSum: BigUInt,
        withdrawable: BigUInt
    ) {
        self.controlled = controlled
        self.drep = drep
        self.epoch = epoch
        self.latestReward = latestReward
        self.poolId = poolId
        self.refundDeposit = refundDeposit
        self.registered = registered
        self.rewardsSum = rewardsSum
        self.withdrawable = withdrawable
    }
}

/// What the person asked to do with the stake key.
public enum CardanoStakingAction: Codable, Equatable, Sendable {
    case changeDRep(CardanoDRep)
    case changePool(String)
    case stake(pool: String, drep: CardanoDRep?)
    case stopStaking
    case withdraw
}

/// A built, unsigned staking transaction and what it moves.
public struct CardanoPreparedStaking: Codable, Sendable {
    /// Lovelace deposited.
    public let deposit: BigUInt
    /// Lovelace moved to the account, net of the fee, deposit, refund and withdrawal.
    public let netLovelace: BigInt
    /// Lovelace refunded by deregistration.
    public let refund: BigUInt
    public let unsigned: CardanoUnsignedTransaction
    /// Lovelace withdrawn from the reward account.
    public let withdrawal: BigUInt

    public init(
        deposit: BigUInt,
        netLovelace: BigInt,
        refund: BigUInt,
        unsigned: CardanoUnsignedTransaction,
        withdrawal: BigUInt
    ) {
        self.deposit = deposit
        self.netLovelace = netLovelace
        self.refund = refund
        self.unsigned = unsigned
        self.withdrawal = withdrawal
    }

    public var fee: BigUInt { BigUInt(unsigned.fee) ?? 0 }

    /// What the transaction spends, for tracking it after it is sent.
    public var pendingSubmission: CardanoPendingSubmission? {
        guard let ttl = unsigned.ttl, let hash = try? hash() else {
            return nil
        }

        let inputs = unsigned.inputs.map { CardanoSpentInput(outputIndex: $0.outputIndex, producer: $0.txHash) }

        return CardanoPendingSubmission(hash: hash, inputs: inputs, ttl: ttl)
    }

    /// The transaction's hash, known before it is signed or sent.
    public func hash() throws -> String {
        try unsigned.transactionBodyHash().map { String(format: "%02x", $0) }.joined()
    }

    /// The JSON envelope `TransactionService` signs and broadcasts.
    public func envelope() throws -> Data {
        try JSONEncoder().encode(unsigned)
    }
}

/// A broadcast whose outcome isn't known yet.
public struct CardanoPendingSubmission: Codable, Equatable, Sendable {
    public let hash: String
    /// The outputs it spends, so a different transaction consuming one is noticed on every check.
    public let inputs: [CardanoSpentInput]
    public let ttl: UInt64

    public init(hash: String, inputs: [CardanoSpentInput] = [], ttl: UInt64) {
        self.hash = hash
        self.inputs = inputs
        self.ttl = ttl
    }

    /// Submissions stored before inputs were kept have none.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        hash = try container.decode(String.self, forKey: .hash)
        inputs = try container.decodeIfPresent([CardanoSpentInput].self, forKey: .inputs) ?? []
        ttl = try container.decode(UInt64.self, forKey: .ttl)
    }
}

/// An output a transaction spends: its producing transaction (hex) and index.
public struct CardanoSpentInput: Codable, Equatable, Sendable {
    public let outputIndex: UInt32
    public let txHash: String

    public init(outputIndex: UInt32, txHash: String) {
        self.outputIndex = outputIndex
        self.txHash = txHash
    }

    init(outputIndex: UInt32, producer: Data) {
        self.init(outputIndex: outputIndex, txHash: producer.map { String(format: "%02x", $0) }.joined())
    }
}

/// Where a submitted transaction stands.
public enum CardanoSubmissionState: Equatable, Sendable {
    case confirmed
    case expired
    case pending
}

public enum CardanoStakingError: Error, Equatable, LocalizedError {
    case drepUnavailable
    case missingRefund
    case notEnoughADA(shortfall: BigUInt)
    case poolUnavailable
    case rewardsOutstanding
    case unregistered

    public var errorDescription: String? {
        switch self {
        case .drepUnavailable: "This DRep isn't registered or has retired."
        case .missingRefund: "The stake key's deposit couldn't be read, so Stop Staking is unavailable."
        case let .notEnoughADA(shortfall): "Not enough ADA. \(shortfall) lovelace short."
        case .poolUnavailable: "This pool no longer exists, or is retiring."
        case .rewardsOutstanding: "Withdraw rewards before deregistering."
        case .unregistered: "The stake key isn't registered."
        }
    }
}

/// Reads and the Staking section of `CardanoUnsignedTransaction`'s envelope.
public struct CardanoStakingSummary: Codable, Equatable, Sendable {
    public let deposit: String
    public let refund: String
    public let withdrawal: String

    public init(deposit: String, refund: String, withdrawal: String) {
        self.deposit = deposit
        self.refund = refund
        self.withdrawal = withdrawal
    }
}

enum CardanoStakingLabel {
    /// A history label from decoded certificate kinds and withdrawals.
    static func method(kinds: [String], hasWithdrawal: Bool) -> String? {
        var labels: [String] = []

        if kinds.contains("StakeDeregistration") {
            labels.append("Stop Staking")
        } else {
            let registers = kinds.contains { $0.contains("Registration") && $0 != "StakeDeregistration" }
            let delegates = kinds.contains { $0.contains("StakeDelegation") || $0 == "StakeAndVoteDelegation" }
            let votes = kinds.contains { $0.contains("VoteDelegation") || $0 == "StakeAndVoteDelegation" }

            if registers {
                labels.append("Stake")
            } else if delegates {
                labels.append("Delegate")
            }

            if votes {
                labels.append("Vote Delegation")
            }

            if hasWithdrawal {
                labels.append("Withdraw Rewards")
            }
        }

        return labels.isEmpty ? nil : labels.joined(separator: " + ")
    }
}
