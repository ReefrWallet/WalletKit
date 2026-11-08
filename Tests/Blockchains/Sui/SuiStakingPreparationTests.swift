// Preparation, funding and submission-recovery coverage against a scripted
// chain. The gas figures are the ones a real mainnet withdrawal simulation
// reported: 100_000 computation, ~0.908 SUI storage cost, ~0.907 SUI rebate.

import Foundation
import Testing
@testable import WalletKit

/// A scripted node: every answer is set up front, every simulated transaction is recorded.
actor FakeSuiChain: SuiStakingChain {
    var broadcastCount = 0
    var broadcastError: Error?
    var broadcastDigest: String?
    var coins: [SuiCoinObject] = []
    var consuming: [String: String] = [:]
    var consumingErrors: Set<String> = []
    var info = SuiServiceInfo(chainId: "chain", epoch: 100, checkpointHeight: 5000, lowestAvailableCheckpoint: 0)
    var infoError: Error?
    var live: [String: SuiObjectReference?] = [:]
    var simulate: @Sendable (Int, Data) -> SuiSimulationResult = { _, _ in
        let gas = SuiGasCostSummary(computationCost: 100_000, storageCost: 908_116_400, storageRebate: 907_037_687)
        return SuiSimulationResult(failure: nil, gas: gas)
    }

    var simulated: [Data] = []
    var status: SuiTransactionStatus = .notFound

    func set(coins: [SuiCoinObject]) { self.coins = coins }
    func set(info: SuiServiceInfo) { self.info = info }
    func set(infoError: Error?) { self.infoError = infoError }
    func set(live: [String: SuiObjectReference?]) { self.live = live }
    func set(consuming: [String: String]) { self.consuming = consuming }
    func set(consumingErrors: Set<String>) { self.consumingErrors = consumingErrors }
    func set(status: SuiTransactionStatus) { self.status = status }
    func set(broadcastError: Error?) { self.broadcastError = broadcastError }
    func set(broadcastDigest: String?) { self.broadcastDigest = broadcastDigest }
    func set(simulate: @escaping @Sendable (Int, Data) -> SuiSimulationResult) { self.simulate = simulate }

    func broadcast(transactionData: Data, signature: Data) async throws -> String {
        broadcastCount += 1
        if let broadcastError {
            throw broadcastError
        }

        return broadcastDigest ?? ""
    }

    func consumingTransaction(of reference: SuiObjectReference) async throws -> String? {
        if consumingErrors.contains(reference.objectId.hexEncoded) {
            throw BlockchainClientError.rpcError(code: 5, message: "object not found")
        }

        return consuming[reference.objectId.hexEncoded]
    }

    func liveObjectReference(id: String) async throws -> SuiObjectReference? {
        live[id] ?? nil
    }

    func referenceGasPrice() async throws -> UInt64 { 1000 }

    func serviceInfo() async throws -> SuiServiceInfo {
        if let infoError {
            throw infoError
        }

        return info
    }

    func simulate(transactionData: Data) async throws -> SuiSimulationResult {
        simulated.append(transactionData)
        return simulate(simulated.count, transactionData)
    }

    func suiCoins(of owner: SuiAddress) async throws -> [SuiCoinObject] { coins }

    func transactionStatus(digest: String) async throws -> SuiTransactionStatus { status }
}

private let oneSui: UInt64 = 1_000_000_000

private func coin(_ byte: UInt8, sui: UInt64) -> SuiCoinObject {
    SuiCoinObject(
        reference: SuiObjectReference(
            objectId: Data(repeating: byte, count: 32), version: 7, digest: Data(repeating: byte &+ 1, count: 32)
        ),
        balance: sui
    )
}

private func address(_ byte: UInt8) throws -> SuiAddress {
    try SuiAddress(rawBytes: Data(repeating: byte, count: 32))
}

private func stakedSui(principal: UInt64 = 10 * oneSui) -> SuiStakedSui {
    SuiStakedSui(
        objectId: Data(repeating: 0xBB, count: 32).hexEncoded,
        version: 9,
        digest: Base58.encode(Data(repeating: 0xB1, count: 32)),
        poolId: "0x" + String(repeating: "02", count: 32),
        activationEpoch: 5,
        principal: principal
    )
}

struct SuiStakingFundingTests {
    @Test
    func budgetIsAMultipleOfNetCostButNeverBelowTheFloor() {
        let small = SuiGasCostSummary(computationCost: 100_000, storageCost: 908_116_400, storageRebate: 907_037_687)
        #expect(SuiStakingFunding.gasBudget(for: small) == 5_000_000)

        let large = SuiGasCostSummary(computationCost: 100_000, storageCost: 909_104_400, storageRebate: 900_000_000)
        #expect(SuiStakingFunding.gasBudget(for: large) == (100_000 + 9_104_400) * 3)

        let huge = SuiGasCostSummary(computationCost: .max, storageCost: .max, storageRebate: 0)
        #expect(SuiStakingFunding.gasBudget(for: huge) == .max)
    }

    @Test
    func budgetCoversComputationEvenWhenTheRebateShrinksTheNetCost() {
        let gas = SuiGasCostSummary(computationCost: 10_000_000, storageCost: 5_000_000, storageRebate: 14_000_000)
        #expect(gas.netCost == 1_000_000)
        #expect(SuiStakingFunding.gasBudget(for: gas) == 30_000_000)
    }

    @Test
    func maximumStakeKeepsGasAndTheUnstakeReserve() {
        let liquid = 10 * oneSui
        #expect(SuiStakingFunding.maximumStake(liquid: liquid, gasBudget: 5_000_000) == liquid - 25_000_000)
        #expect(SuiStakingFunding.maximumStake(liquid: oneSui + 24_999_999, gasBudget: 5_000_000) == nil)
        #expect(SuiStakingFunding.maximumStake(liquid: oneSui + 25_000_000, gasBudget: 5_000_000) == oneSui)
        #expect(SuiStakingFunding.maximumStake(liquid: 10, gasBudget: .max) == nil)
    }

    @Test
    func leftForGasShowsWhatRemainsAfterAnAmountExceedingMax() {
        let remaining = SuiStakingFunding.leftForGas(liquid: 10 * oneSui, amount: 9 * oneSui, gasBudget: 5_000_000)
        #expect(remaining == oneSui - 5_000_000)
        #expect(SuiStakingFunding.leftForGas(liquid: oneSui, amount: 2 * oneSui, gasBudget: 5_000_000) == 0)
    }

    @Test
    func partialUnstakeLeavesAtLeastTheMinimumOnBothSides() throws {
        #expect(SuiStakingFunding.maximumPartialUnstake(principal: 2 * oneSui) == oneSui)
        #expect(SuiStakingFunding.maximumPartialUnstake(principal: 2 * oneSui - 1) == nil)
        #expect(SuiStakingFunding.maximumPartialUnstake(principal: oneSui) == nil)

        let stake = stakedSui(principal: 3 * oneSui)
        try SuiStakingFunding.validate(.unstakePartial(stake, amount: 2 * oneSui))
        #expect(throws: SuiStakingError.remainderBelowMinimum(minimum: oneSui)) {
            try SuiStakingFunding.validate(.unstakePartial(stake, amount: 2 * oneSui + 1))
        }
        #expect(throws: SuiStakingError.belowMinimumStake(minimum: oneSui)) {
            try SuiStakingFunding.validate(.unstakePartial(stake, amount: oneSui - 1))
        }
        #expect(throws: SuiStakingError.belowMinimumStake(minimum: oneSui)) {
            try SuiStakingFunding.validate(.stake(validator: try address(0x22), amount: oneSui - 1))
        }
    }
}

struct SuiStakingPreparationTests {
    private let owner: SuiAddress
    private let validator: SuiAddress

    init() throws {
        owner = try address(0x11)
        validator = try address(0x22)
    }

    private func prepare(
        _ action: SuiStakingAction, chain: FakeSuiChain
    ) async throws -> SuiPreparedStaking {
        try await SuiStakingPreparation(chain: chain).prepare(action, owner: owner)
    }

    @Test
    func stakeSignsExactlyTheBytesItLastSimulated() async throws {
        let chain = FakeSuiChain()
        await chain.set(coins: [coin(0xAA, sui: 10 * oneSui)])

        let prepared = try await prepare(.stake(validator: validator, amount: 5 * oneSui), chain: chain)

        let simulated = await chain.simulated
        #expect(simulated.count >= 2, "a draft pass and a final pass")
        #expect(simulated.last == prepared.transactionData)
        #expect(prepared.gasBudget == 5_000_000)
        #expect(prepared.expirationEpoch == 101)
        #expect(prepared.chainId == "chain")
        #expect(prepared.startCheckpoint == 5000)
        #expect(prepared.leftForGas == 5 * oneSui - 5_000_000)
        #expect(prepared.netFee == 1_178_713)
        #expect(prepared.inputs.map(\.objectId) == [Data(repeating: 0xAA, count: 32).hexEncoded])
        #expect(prepared.digest == prepared.transaction.digest)

        let summary = try #require(SuiTransactionDataDecoder.summarize(prepared.transactionData, policy: .wallet))
        #expect(summary.gasBudget == 5_000_000)
        #expect(summary.expirationEpoch == 101)
    }

    @Test
    func stakeNeedsLiquidSuiForTheAmountAndGas() async throws {
        let chain = FakeSuiChain()
        await chain.set(coins: [coin(0xAA, sui: 5 * oneSui + 1_000_000)])

        let expected = SuiStakingError.insufficientFunds(
            needed: 5 * oneSui + 5_000_000, available: 5 * oneSui + 1_000_000
        )

        await #expect(throws: expected) {
            try await prepare(.stake(validator: validator, amount: 5 * oneSui), chain: chain)
        }
    }

    @Test
    func gasIsDrawnFromSeveralCoinsWhenOneIsNotEnough() async throws {
        let chain = FakeSuiChain()
        await chain.set(coins: [coin(0xAA, sui: 3 * oneSui), coin(0xAC, sui: 3 * oneSui)])

        let prepared = try await prepare(.stake(validator: validator, amount: 5 * oneSui), chain: chain)
        #expect(prepared.inputs.count == 2)
    }

    @Test
    func aFailedSimulationIsReportedNotSigned() async throws {
        let chain = FakeSuiChain()
        await chain.set(coins: [coin(0xAA, sui: 10 * oneSui)])
        await chain.set { _, _ in
            let gas = SuiGasCostSummary(computationCost: 1, storageCost: 0, storageRebate: 0)
            return SuiSimulationResult(failure: "MoveAbort", gas: gas)
        }

        await #expect(throws: SuiStakingError.simulationFailed("MoveAbort")) {
            try await prepare(.stake(validator: validator, amount: 5 * oneSui), chain: chain)
        }
    }

    @Test
    func aBudgetThatTheFinalSimulationOutgrowsIsRaisedAndResimulated() async throws {
        let chain = FakeSuiChain()
        await chain.set(coins: [coin(0xAA, sui: 10 * oneSui)])
        // Draft is cheap; the exact bytes cost more than the draft suggested.
        await chain.set { call, _ in
            let storage: UInt64 = call == 1 ? 908_116_400 : 908_116_400 + 4_000_000
            return SuiSimulationResult(
                failure: nil,
                gas: SuiGasCostSummary(computationCost: 100_000, storageCost: storage, storageRebate: 907_037_687)
            )
        }

        let prepared = try await prepare(.stake(validator: validator, amount: 5 * oneSui), chain: chain)
        let simulated = await chain.simulated
        #expect(simulated.count == 3)
        #expect(prepared.gasBudget == (1_178_713 + 4_000_000) * 3)
        #expect(simulated.last == prepared.transactionData)
    }

    /// What a node does when the budget is too small: the transaction fails with a typed insufficient-gas
    /// status, charging the whole budget as computation.
    private static func nodeBilling(minimumBudget: UInt64) -> @Sendable (Int, Data) -> SuiSimulationResult {
        { _, bytes in
            let budget = SuiTransactionDataDecoder.summarize(bytes, policy: .wallet)?.gasBudget ?? 0
            guard budget >= minimumBudget else {
                let gas = SuiGasCostSummary(computationCost: budget, storageCost: 0, storageRebate: 0)
                return SuiSimulationResult(failure: "InsufficientGas", gas: gas, isInsufficientGas: true)
            }

            let gas = SuiGasCostSummary(computationCost: 100_000, storageCost: 908_116_400, storageRebate: 907_037_687)
            return SuiSimulationResult(failure: nil, gas: gas)
        }
    }

    @Test
    func aBudgetTheNodeCallsInsufficientIsRaisedAndRetried() async throws {
        let chain = FakeSuiChain()
        await chain.set(coins: [coin(0xAA, sui: 10 * oneSui)])
        // The draft succeeds at 0.1 SUI, but the sized budget (5 M) is below what the node needs.
        await chain.set(simulate: Self.nodeBilling(minimumBudget: 12_000_000))

        let prepared = try await prepare(.stake(validator: validator, amount: 5 * oneSui), chain: chain)

        #expect(prepared.gasBudget >= 12_000_000)
        let simulated = await chain.simulated
        #expect(simulated.count >= 3)
        #expect(simulated.last == prepared.transactionData)
    }

    private static func costing(net: UInt64) -> @Sendable (Int, Data) -> SuiSimulationResult {
        { _, _ in
            let gas = SuiGasCostSummary(computationCost: 100_000, storageCost: net, storageRebate: 100_000)
            return SuiSimulationResult(failure: nil, gas: gas)
        }
    }

    /// 8 M MIST spare, a 3 M net cost: the safety multiple wants 9 M, which the account cannot pay. The
    /// affordable 8 M budget passed simulation as exact bytes, so it is kept rather than raised past the balance.
    @Test
    func anAffordableBudgetThatPassedSimulationIsKeptWhenTheSafetyMultipleIsOutOfReach() async throws {
        let chain = FakeSuiChain()
        await chain.set(coins: [coin(0xAA, sui: 5 * oneSui + 8_000_000)])
        await chain.set(simulate: Self.costing(net: 3_100_000))

        let prepared = try await prepare(.stake(validator: validator, amount: 5 * oneSui), chain: chain)

        #expect(prepared.gasBudget == 8_000_000)
        #expect(await chain.simulated.last == prepared.transactionData)
        #expect(prepared.leftForGas == 0)
    }

    @Test
    func aSpareBelowTheMinimumBudgetIsStillInsufficientFunds() async throws {
        let chain = FakeSuiChain()
        await chain.set(coins: [coin(0xAA, sui: 5 * oneSui + 4_000_000)])
        await chain.set(simulate: Self.costing(net: 3_100_000))

        await #expect(throws: SuiStakingError.self) {
            try await prepare(.stake(validator: validator, amount: 5 * oneSui), chain: chain)
        }
    }

    @Test
    func anInsufficientDraftIsRaisedToo() async throws {
        let chain = FakeSuiChain()
        await chain.set(coins: [coin(0xAA, sui: 10 * oneSui)])
        // Even the 0.1 SUI draft is too little.
        await chain.set(simulate: Self.nodeBilling(minimumBudget: 300_000_000))

        let prepared = try await prepare(.stake(validator: validator, amount: 5 * oneSui), chain: chain)
        #expect(prepared.gasBudget >= 300_000_000)
        #expect(await chain.simulated.last == prepared.transactionData)
    }

    @Test
    func anInsufficientBudgetThatCannotBeRaisedFurtherIsReportedAsInsufficientFunds() async throws {
        let chain = FakeSuiChain()
        await chain.set(coins: [coin(0xAA, sui: 5 * oneSui + 6_000_000)])
        await chain.set(simulate: Self.nodeBilling(minimumBudget: 12_000_000))

        await #expect(throws: SuiStakingError.self) {
            try await prepare(.stake(validator: validator, amount: 5 * oneSui), chain: chain)
        }

        let simulated = await chain.simulated
        #expect(!simulated.isEmpty)
    }

    @Test
    func aNetworkWhoseCostKeepsGrowingIsRefused() async throws {
        let chain = FakeSuiChain()
        await chain.set(coins: [coin(0xAA, sui: 10 * oneSui)])
        await chain.set { call, _ in
            SuiSimulationResult(
                failure: nil,
                gas: SuiGasCostSummary(computationCost: UInt64(call) * 50_000_000, storageCost: 0, storageRebate: 0)
            )
        }

        await #expect(throws: SuiStakingError.gasUnstable) {
            try await prepare(.stake(validator: validator, amount: 5 * oneSui), chain: chain)
        }
    }

    @Test
    func unstakeOnlyNeedsGasAndMustMatchTheReceiptOnChain() async throws {
        let stake = stakedSui()
        let chain = FakeSuiChain()
        await chain.set(coins: [coin(0xAA, sui: 10_000_000)])
        await chain.set(live: [stake.objectId: try stake.reference()])

        let prepared = try await prepare(.unstake(stake), chain: chain)
        #expect(prepared.inputs.map(\.objectId).contains(stake.objectId))
        #expect(prepared.leftForGas == 5_000_000)

        let partial = try await prepare(.unstakePartial(stake, amount: 2 * oneSui), chain: chain)
        let summary = try #require(SuiTransactionDataDecoder.summarize(partial.transactionData, policy: .wallet))
        #expect(summary.moveCalls.map(\.function) == ["split", "request_withdraw_stake"])
    }

    @Test
    func aReceiptThatChangedOnChainIsRefused() async throws {
        let stake = stakedSui()
        let chain = FakeSuiChain()
        await chain.set(coins: [coin(0xAA, sui: 10_000_000)])
        let moved = SuiObjectReference(
            objectId: try Data(hexString: stake.objectId), version: 10, digest: Data(repeating: 0xB2, count: 32)
        )

        await chain.set(live: [stake.objectId: moved])

        await #expect(throws: SuiStakingError.stakeChanged) {
            try await prepare(.unstake(stake), chain: chain)
        }

        await chain.set(live: [stake.objectId: nil])
        await #expect(throws: SuiStakingError.stakeChanged) {
            try await prepare(.unstake(stake), chain: chain)
        }
    }
}
