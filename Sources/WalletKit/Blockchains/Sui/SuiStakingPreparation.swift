//
//  SuiStakingPreparation.swift
//  WalletKit
//
//  Created by Andrey Yurkevich on 08/11/2026.
//  Copyright © 2026 Reefr Wallet. All rights reserved.
//
//  Turns a staking request into the exact bytes to sign. Two simulation
//  passes: a draft sizes the gas budget; then the exact bytes (expiry, coins,
//  amount, budget) are simulated, and only those are ever returned.

import Foundation

/// What the user asked for.
public enum SuiStakingAction: Sendable, Equatable {
    case stake(validator: SuiAddress, amount: UInt64)
    case unstake(SuiStakedSui)
    case unstakePartial(SuiStakedSui, amount: UInt64)

    public var kind: SuiStakingActionKind {
        switch self {
        case .stake: .stake
        case .unstake: .unstake
        case .unstakePartial: .unstakePartial
        }
    }

    /// The amount that leaves the gas coin: only a stake spends SUI beyond gas.
    var stakedAmount: UInt64 {
        guard case let .stake(_, amount) = self else {
            return 0
        }

        return amount
    }

    var stakedSui: SuiStakedSui? {
        switch self {
        case .stake: nil
        case let .unstake(stake), let .unstakePartial(stake, _): stake
        }
    }
}

public enum SuiStakingActionKind: String, Sendable, Equatable, Codable {
    case stake
    case unstake
    case unstakePartial
}

public enum SuiStakingError: Error, Equatable {
    case belowMinimumStake(minimum: UInt64)
    /// The gas budget the exact transaction needs kept growing; the network is too volatile to sign safely.
    case gasUnstable
    case insufficientFunds(needed: UInt64, available: UInt64)
    case remainderBelowMinimum(minimum: UInt64)
    case simulationFailed(String)
    /// The receipt on chain is not the one the request was made for (already split, withdrawn, or replaced).
    case stakeChanged
}

/// Gas and amount rules, kept free of the network so they can be tested exhaustively.
public enum SuiStakingFunding {
    /// The smallest gas budget ever used, in MIST (0.005 SUI).
    public static let minimumGasBudget: UInt64 = 5_000_000
    /// Upper bound for the draft simulation's budget (0.1 SUI).
    public static let draftGasBudget: UInt64 = 100_000_000
    /// Safety multiple applied to the simulated net cost.
    static let budgetMultiple: UInt64 = 3
    /// Held back from MAX so an unstake is always affordable (0.02 SUI). Mainnet withdrawals net about
    /// 0.001 to 0.002 SUI, so this is several budgets of headroom; it is an estimate, not a guarantee.
    public static let unstakeReserve: UInt64 = 20_000_000

    /// Sui checks the budget against the computation cost and against computation plus storage cost *net of
    /// the rebate*, so the budget is a multiple of the larger of the two rather than of the gross (which for
    /// staking includes a large, refunded system-state rewrite).
    public static func gasBudget(for gas: SuiGasCostSummary) -> UInt64 {
        let (scaled, overflow) = max(gas.computationCost, gas.netCost).multipliedReportingOverflow(by: budgetMultiple)
        return overflow ? .max : max(minimumGasBudget, scaled)
    }

    /// The most that can be staked from `liquid` while still paying `gasBudget` and keeping the unstake
    /// reserve; `nil` if that would fall below the minimum stake.
    public static func maximumStake(liquid: UInt64, gasBudget: UInt64) -> UInt64? {
        let (held, overflow) = gasBudget.addingReportingOverflow(unstakeReserve)
        guard !overflow, liquid > held, liquid - held >= SuiStakingFramework.minimumStake else {
            return nil
        }

        return liquid - held
    }

    /// Liquid SUI left for gas once `amount` is staked and `gasBudget` is set aside.
    public static func leftForGas(liquid: UInt64, amount: UInt64, gasBudget: UInt64) -> UInt64 {
        let (spent, overflow) = amount.addingReportingOverflow(gasBudget)
        return overflow || spent > liquid ? 0 : liquid - spent
    }

    /// The largest partial unstake of a `principal` stake: everything but the minimum that must stay.
    public static func maximumPartialUnstake(principal: UInt64) -> UInt64? {
        let minimum = SuiStakingFramework.minimumStake
        return principal >= 2 * minimum ? principal - minimum : nil
    }

    public static func validate(_ action: SuiStakingAction) throws {
        let minimum = SuiStakingFramework.minimumStake
        switch action {
        case let .stake(_, amount):
            guard amount >= minimum else {
                throw SuiStakingError.belowMinimumStake(minimum: minimum)
            }

        case .unstake:
            break
        case let .unstakePartial(stake, amount):
            guard amount >= minimum else {
                throw SuiStakingError.belowMinimumStake(minimum: minimum)
            }

            guard amount <= stake.principal, stake.principal - amount >= minimum else {
                throw SuiStakingError.remainderBelowMinimum(minimum: minimum)
            }
        }
    }

    /// The smallest prefix of `coins` (largest first) worth at least `needed`.
    static func selectCoins(from coins: [SuiCoinObject], needed: UInt64) -> [SuiCoinObject]? {
        var selected: [SuiCoinObject] = []
        var total: UInt64 = 0
        for coin in coins.sorted(by: { $0.balance > $1.balance }) {
            selected.append(coin)
            total = total.addingReportingOverflow(coin.balance).overflow ? .max : total + coin.balance
            if total >= needed {
                return selected
            }
        }

        return nil
    }
}

/// A transaction ready to sign, with what recovery needs to follow it.
public struct SuiPreparedStaking: Sendable, Equatable {
    public let action: SuiStakingAction
    public let chainId: String
    public let digest: Data
    public let expirationEpoch: UInt64
    public let gasBudget: UInt64
    /// Every object the transaction consumes or mutates, at the versions it was built against.
    public let inputs: [SuiInputRef]
    /// SUI left liquid after the amount and gas budget are set aside.
    public let leftForGas: UInt64
    /// The simulated net cost: computation plus storage, minus rebate.
    public let netFee: UInt64
    /// The latest executed checkpoint read before building; recovery scans no earlier than this.
    public let startCheckpoint: UInt64
    public let transaction: SuiProgrammableTransaction

    public var transactionData: Data { transaction.transactionDataBcs }

    public init(
        action: SuiStakingAction,
        chainId: String,
        digest: Data,
        expirationEpoch: UInt64,
        gasBudget: UInt64,
        inputs: [SuiInputRef],
        leftForGas: UInt64,
        netFee: UInt64,
        startCheckpoint: UInt64,
        transaction: SuiProgrammableTransaction
    ) {
        self.action = action
        self.chainId = chainId
        self.digest = digest
        self.expirationEpoch = expirationEpoch
        self.gasBudget = gasBudget
        self.inputs = inputs
        self.leftForGas = leftForGas
        self.netFee = netFee
        self.startCheckpoint = startCheckpoint
        self.transaction = transaction
    }
}

public struct SuiStakingPreparation: Sendable {
    private static let maxPasses = 6

    /// What every pass needs, read once.
    private struct Context {
        let action: SuiStakingAction
        let coins: [SuiCoinObject]
        let gasPrice: UInt64
        let info: SuiServiceInfo
        let liquid: UInt64
        let owner: SuiAddress
        let stakeReference: SuiObjectReference?

        var amount: UInt64 { action.stakedAmount }
    }

    /// One simulated attempt: the exact transaction and what the node said about it.
    private struct Pass {
        let coins: [SuiCoinObject]
        let result: SuiSimulationResult
        let transaction: SuiProgrammableTransaction
    }

    private let chain: any SuiStakingChain

    public init(chain: any SuiStakingChain) {
        self.chain = chain
    }

    private static func sum(_ lhs: UInt64, _ rhs: UInt64) -> UInt64 {
        lhs.addingReportingOverflow(rhs).overflow ? .max : lhs + rhs
    }

    public func prepare(_ action: SuiStakingAction, owner: SuiAddress) async throws -> SuiPreparedStaking {
        try SuiStakingFunding.validate(action)
        let context = try await read(action, owner: owner)

        let spare = context.liquid > context.amount ? context.liquid - context.amount : 0
        guard spare > 0 else {
            let needed = Self.sum(context.amount, SuiStakingFunding.minimumGasBudget)
            throw SuiStakingError.insufficientFunds(needed: needed, available: context.liquid)
        }

        // The first pass is a draft at a generous budget that sizes the real one; every later pass simulates
        // the exact bytes. A budget the node calls insufficient is raised, a settled one is returned.
        var budget = min(SuiStakingFunding.draftGasBudget, spare)
        var isDraft = true
        var sawInsufficientGas = false
        for _ in 0..<Self.maxPasses {
            let pass = try await simulate(context, budget: budget)
            if pass.result.isInsufficientGas {
                sawInsufficientGas = true
                budget = try raised(budget, after: pass.result.gas, context: context, spare: spare)
                continue
            }

            let required = SuiStakingFunding.gasBudget(for: pass.result.gas)
            if isDraft || required > budget {
                // Once the node has refused a budget, never size back down below one it accepted.
                let target = sawInsufficientGas ? max(required, budget) : required
                if target > spare, spare >= SuiStakingFunding.minimumGasBudget {
                    // The safety multiple is out of reach. An affordable budget whose exact bytes passed
                    // simulation is still safe to sign; a draft has not been tried at the cap yet.
                    guard !isDraft else {
                        isDraft = false
                        budget = spare
                        continue
                    }

                    return prepared(context, pass: pass, budget: budget)
                }

                isDraft = false
                budget = target
                continue
            }

            return prepared(context, pass: pass, budget: budget)
        }

        throw SuiStakingError.gasUnstable
    }

    /// The budget after the node reported `budget` insufficient: at least double, at least what the
    /// simulation says it cost, never more than the account can pay.
    private func raised(
        _ budget: UInt64, after gas: SuiGasCostSummary, context: Context, spare: UInt64
    ) throws -> UInt64 {
        let target = max(Self.sum(budget, budget), SuiStakingFunding.gasBudget(for: gas))
        let capped = min(target, spare)
        guard capped > budget else {
            throw SuiStakingError.insufficientFunds(
                needed: Self.sum(context.amount, target), available: context.liquid
            )
        }

        return capped
    }

    private func read(_ action: SuiStakingAction, owner: SuiAddress) async throws -> Context {
        async let infoRead = chain.serviceInfo()
        async let priceRead = chain.referenceGasPrice()
        async let coinsRead = chain.suiCoins(of: owner)
        let (info, gasPrice, coins) = try await (infoRead, priceRead, coinsRead)
        let liquid = coins.reduce(UInt64(0)) { Self.sum($0, $1.balance) }
        return Context(
            action: action,
            coins: coins,
            gasPrice: gasPrice,
            info: info,
            liquid: liquid,
            owner: owner,
            stakeReference: try await currentReference(of: action)
        )
    }

    private func simulate(_ context: Context, budget: UInt64) async throws -> Pass {
        let needed = Self.sum(context.amount, budget)
        guard let coins = SuiStakingFunding.selectCoins(from: context.coins, needed: needed) else {
            throw SuiStakingError.insufficientFunds(needed: needed, available: context.liquid)
        }

        return try await simulate(context, coins: coins, budget: budget)
    }

    private func simulate(_ context: Context, coins: [SuiCoinObject], budget: UInt64) async throws -> Pass {
        let envelope = SuiStakingEnvelope(
            sender: context.owner,
            gasPayment: coins.map(\.reference),
            gasPrice: context.gasPrice,
            gasBudget: budget,
            expirationEpoch: context.info.epoch + 1
        )

        let transaction = try build(context.action, context.stakeReference, envelope)
        let result = try await chain.simulate(transactionData: transaction.transactionDataBcs)
        if let failure = result.failure, !result.isInsufficientGas {
            throw SuiStakingError.simulationFailed(failure)
        }

        return Pass(coins: coins, result: result, transaction: transaction)
    }

    private func prepared(_ context: Context, pass: Pass, budget: UInt64) -> SuiPreparedStaking {
        let stakeInputs = context.stakeReference.map { [SuiInputRef($0)] } ?? []
        return SuiPreparedStaking(
            action: context.action,
            chainId: context.info.chainId,
            digest: pass.transaction.digest,
            expirationEpoch: context.info.epoch + 1,
            gasBudget: budget,
            inputs: pass.coins.map { SuiInputRef($0.reference) } + stakeInputs,
            leftForGas: SuiStakingFunding.leftForGas(liquid: context.liquid, amount: context.amount, gasBudget: budget),
            netFee: pass.result.gas.netCost,
            startCheckpoint: context.info.checkpointHeight,
            transaction: pass.transaction
        )
    }

    /// For an unstake, the receipt as it is on chain now; it must be the one the request names.
    private func currentReference(of action: SuiStakingAction) async throws -> SuiObjectReference? {
        guard let stake = action.stakedSui else {
            return nil
        }

        let requested = try stake.reference()
        guard try await chain.liveObjectReference(id: stake.objectId) == requested else {
            throw SuiStakingError.stakeChanged
        }

        return requested
    }

    private func build(
        _ action: SuiStakingAction, _ stakeReference: SuiObjectReference?, _ envelope: SuiStakingEnvelope
    ) throws -> SuiProgrammableTransaction {
        switch action {
        case let .stake(validator, amount):
            return try SuiStakingTransactions.stake(amount: amount, validator: validator, envelope: envelope)
        case .unstake:
            let stake = try requireReference(stakeReference)
            return try SuiStakingTransactions.withdraw(stakedSui: stake, envelope: envelope)
        case let .unstakePartial(_, amount):
            let stake = try requireReference(stakeReference)
            return try SuiStakingTransactions.withdrawPartial(stakedSui: stake, amount: amount, envelope: envelope)
        }
    }

    private func requireReference(_ reference: SuiObjectReference?) throws -> SuiObjectReference {
        guard let reference else {
            throw SuiStakingError.stakeChanged
        }

        return reference
    }
}
