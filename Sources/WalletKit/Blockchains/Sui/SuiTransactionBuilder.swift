//
//  SuiTransactionBuilder.swift
//  WalletKit
//
//  Created by Andrey Yurkevich on 28/08/2026.
//  Copyright © 2026 Reefr Wallet. All rights reserved.
//

import BigInt
import Foundation

/// A ``BlockchainTransactionBuilderProtocol`` implementation for Sui,
/// backed by a ``SuiGRPCClient``.
///
/// Builds BCS-encoded `TransactionData` for native SUI and arbitrary-coin
/// transfers. The builder simulates each transaction to select an adequate
/// gas-coin set and budget.
public struct SuiTransactionBuilder: BlockchainTransactionBuilderProtocol {
    public typealias Address = SuiAddress

    private let client: SuiGRPCClient

    /// The target gas budget used for simulation — large enough to cover
    /// any realistic Sui transaction. The actual simulation budget is capped
    /// by the sender's available balance, so this value is only an upper bound.
    private static let simulationBudget: UInt64 = 50_000_000 // 50 M MIST

    /// Canonical 64-hex-digit form of the native SUI coin type.
    private static let nativeSuiCoinType =
        "0x0000000000000000000000000000000000000000000000000000000000000002::sui::SUI"

    /// Creates a builder backed by `client`.
    ///
    /// - Parameter client: The ``SuiGRPCClient`` to use for fetching
    ///   the reference gas price, owned coin objects, and for simulating
    ///   the transaction.
    public init(client: SuiGRPCClient) {
        self.client = client
    }

    /// Builds unsigned BCS `TransactionData` bytes for a transfer of
    /// `amount` of `token` from `sender` to `recipient`.
    ///
    /// - Parameters:
    ///   - sender: The account that will sign and pay gas.
    ///   - recipient: The transfer destination.
    ///   - amount: Amount in MIST (for SUI or any other Sui coin type's
    ///     smallest unit).
    ///   - token: `nil` or any equivalent form of `"0x2::sui::SUI"`
    ///     (e.g. the full 64-digit address) for native SUI; a coin-type
    ///     string (e.g. `"0x5d4b302506645c37ff133b98c4b50a4ae4023"`) for
    ///     any other coin.
    ///   - options: Builder flags, including an optional Sui gas override.
    /// - Returns: BCS `TransactionData` bytes ready for
    ///   ``SuiPKeySigner/sign(transaction:)``.
    /// - Throws: ``BlockchainTransactionBuilderError/insufficientFunds(reason:)``
    ///   when there are no coins or their total is below `amount`;
    ///   ``BlockchainTransactionBuilderError/amountTooLarge`` when `amount`
    ///   exceeds `UInt64.max`; ``BlockchainClientError`` on gRPC failures or
    ///   a malformed coin type string.
    public func buildTransfer(
        sender: SuiAddress,
        recipient: SuiAddress,
        amount: BigUInt,
        token: String?,
        options: [BlockchainTransactionBuilderOptions]
    ) async throws -> Data {
        guard let amountU64 = UInt64(exactly: amount) else {
            throw BlockchainTransactionBuilderError.amountTooLarge
        }

        let gasOverride = options.suiGasOverride

        // Normalize so that "0x2::sui::SUI" and its full 64-digit equivalent
        // both route to the native path; a malformed type throws decodingFailed.
        let coinType = try MoveTypeTag.canonicalCoinType(token ?? "0x2::sui::SUI")
        if coinType == SuiTransactionBuilder.nativeSuiCoinType {
            return try await buildNativeSuiTransfer(
                sender: sender, recipient: recipient, amount: amountU64, gasOverride: gasOverride
            )
        } else {
            return try await buildTokenTransfer(
                sender: sender, recipient: recipient, amount: amountU64, coinType: coinType, gasOverride: gasOverride
            )
        }
    }
}

// MARK: - Private helpers

private extension SuiTransactionBuilder {
    typealias SuiGasOverride = (budget: UInt64?, price: UInt64?)

    func buildNativeSuiTransfer(
        sender: SuiAddress,
        recipient: SuiAddress,
        amount: UInt64,
        gasOverride: SuiGasOverride?
    ) async throws -> Data {
        let suiCoins = try await client.ownedCoins(of: sender, coinType: "0x2::sui::SUI")
        let totalSUI = suiCoins.reduce(UInt64(0)) { $0 &+ $1.balance }

        guard totalSUI > amount else {
            throw BlockchainTransactionBuilderError.insufficientFunds(
                reason: "need \(amount) MIST + gas but \(sender.string) only has \(totalSUI) MIST"
            )
        }

        // When both budget and price are supplied, skip simulation entirely.
        if let budget = gasOverride?.budget, let price = gasOverride?.price {
            let (needed, overflow) = amount.addingReportingOverflow(budget)
            guard let gasCoins = selectCoins(from: suiCoins, needed: overflow ? .max : needed) else {
                throw BlockchainTransactionBuilderError.insufficientFunds(
                    reason: "need \(amount) MIST + \(budget) MIST gas budget but \(sender.string) only has \(totalSUI) MIST"
                )
            }
            return UnsignedSuiTransaction(
                sender: sender, transfers: [(recipient: recipient, amount: amount)],
                gasPayment: gasCoins.map(\.reference), gasOwner: sender,
                gasPrice: price, gasBudget: budget
            ).transactionDataBcs
        }

        // The ?? operator wraps its RHS in an @autoclosure which doesn't support
        // async/await; use explicit if/else instead.
        let gasPrice: UInt64
        if let overridePrice = gasOverride?.price {
            gasPrice = overridePrice
        } else {
            gasPrice = UInt64(try await client.estimateFee(for: nil as FeeEstimateRequest<SuiAddress>?).gasPrice)
        }

        // Cap simulation budget by available gas so low-balance accounts aren't
        // rejected before the actual fee is known.
        let availableForGas = totalSUI - amount // totalSUI > amount guaranteed above
        let initialSimBudget = min(SuiTransactionBuilder.simulationBudget, availableForGas)
        let (initialNeeded, initOverflow) = amount.addingReportingOverflow(initialSimBudget)
        var gasCoins = selectCoins(from: suiCoins, needed: initOverflow ? .max : initialNeeded) ?? suiCoins

        for _ in 0..<5 {
            let (refined, budget) = try await simulateAndSelectNativeGas(
                sender: sender, recipient: recipient, amount: amount, gasPrice: gasPrice,
                suiCoins: suiCoins, totalSUI: totalSUI, coins: gasCoins
            )
            if refined.count <= gasCoins.count {
                return UnsignedSuiTransaction(
                    sender: sender, transfers: [(recipient: recipient, amount: amount)],
                    gasPayment: refined.map(\.reference), gasOwner: sender,
                    gasPrice: gasPrice, gasBudget: gasOverride?.budget ?? budget
                ).transactionDataBcs
            }
            gasCoins = refined
        }
        throw BlockchainTransactionBuilderError.gasSelectionFailed(
            reason: "gas coin set grew on every iteration for \(sender.string)"
        )
    }

    // swiftlint:disable:next function_body_length
    func buildTokenTransfer(
        sender: SuiAddress,
        recipient: SuiAddress,
        amount: UInt64,
        coinType: String,
        gasOverride: SuiGasOverride?
    ) async throws -> Data {
        let allTokenCoins = try await client.ownedCoins(of: sender, coinType: coinType)
        guard !allTokenCoins.isEmpty else {
            throw BlockchainTransactionBuilderError.insufficientFunds(
                reason: "\(sender.string) owns no coins of type \(coinType)"
            )
        }

        // Select the smallest prefix of token coins whose combined balance covers
        // amount — avoids bloating the PTB with redundant inputs.
        guard let tokenCoins = selectCoins(from: allTokenCoins, needed: amount) else {
            let total = allTokenCoins.reduce(UInt64(0)) { $0 &+ $1.balance }
            throw BlockchainTransactionBuilderError.insufficientFunds(
                reason: "requested \(amount) but \(sender.string) only has \(total) of \(coinType)"
            )
        }

        let suiCoins = try await client.ownedCoins(of: sender, coinType: "0x2::sui::SUI")
        let totalSUI = suiCoins.reduce(UInt64(0)) { $0 &+ $1.balance }

        guard totalSUI > 0 else {
            throw BlockchainTransactionBuilderError.insufficientFunds(
                reason: "\(sender.string) owns no SUI coins for gas"
            )
        }

        // When both budget and price are supplied, skip simulation entirely.
        if let budget = gasOverride?.budget, let price = gasOverride?.price {
            guard let gasCoins = selectCoins(from: suiCoins, needed: budget) else {
                throw BlockchainTransactionBuilderError.insufficientFunds(
                    reason: "need \(budget) MIST gas budget but \(sender.string) only has \(totalSUI) MIST SUI"
                )
            }
            return makeCoinTransferBcs(
                sender: sender, tokenCoins: tokenCoins, amount: amount, recipient: recipient,
                gasCoins: gasCoins.map(\.reference), gasOwner: sender,
                gasPrice: price, gasBudget: budget
            )
        }

        // The ?? operator wraps its RHS in an @autoclosure which doesn't support
        // async/await; use explicit if/else instead.
        let gasPrice: UInt64
        if let overridePrice = gasOverride?.price {
            gasPrice = overridePrice
        } else {
            gasPrice = UInt64(try await client.estimateFee(for: nil as FeeEstimateRequest<SuiAddress>?).gasPrice)
        }

        var gasCoins = selectCoins(from: suiCoins,
                                   needed: min(SuiTransactionBuilder.simulationBudget, totalSUI)) ?? suiCoins

        for _ in 0..<5 {
            let (refined, budget) = try await simulateAndSelectTokenGas(
                sender: sender, tokenCoins: tokenCoins, amount: amount, recipient: recipient,
                gasPrice: gasPrice, suiCoins: suiCoins, totalSUI: totalSUI, coins: gasCoins
            )
            if refined.count <= gasCoins.count {
                return makeCoinTransferBcs(
                    sender: sender, tokenCoins: tokenCoins, amount: amount, recipient: recipient,
                    gasCoins: refined.map(\.reference), gasOwner: sender,
                    gasPrice: gasPrice, gasBudget: gasOverride?.budget ?? budget
                )
            }
            gasCoins = refined
        }
        throw BlockchainTransactionBuilderError.gasSelectionFailed(
            reason: "gas coin set grew on every iteration for \(sender.string)"
        )
    }

    /// Simulates a native SUI split-transfer with `coins` as gas payment and
    /// returns the minimum coin set from `suiCoins` that covers the resulting
    /// budget, paired with that budget.
    func simulateAndSelectNativeGas(
        sender: SuiAddress,
        recipient: SuiAddress,
        amount: UInt64,
        gasPrice: UInt64,
        suiCoins: [SuiCoinObject],
        totalSUI: UInt64,
        coins: [SuiCoinObject]
    ) async throws -> (coins: [SuiCoinObject], budget: UInt64) {
        let coinsTotal = coins.reduce(UInt64(0)) { $0 &+ $1.balance }
        let (gas, underflow) = coinsTotal.subtractingReportingOverflow(amount)
        let capBudget = underflow ? 0 : min(SuiTransactionBuilder.simulationBudget, gas)
        let simTx = UnsignedSuiTransaction(
            sender: sender, transfers: [(recipient: recipient, amount: amount)],
            gasPayment: coins.map(\.reference), gasOwner: sender,
            gasPrice: gasPrice, gasBudget: capBudget
        ).transactionDataBcs
        let budget = try await simulatedBudget(transactionBcs: simTx)
        let (needed, overflow) = amount.addingReportingOverflow(budget)
        guard let refined = selectCoins(from: suiCoins, needed: overflow ? .max : needed) else {
            throw BlockchainTransactionBuilderError.insufficientFunds(
                reason: "need \(amount) MIST + gas but \(sender.string) only has \(totalSUI) MIST"
            )
        }
        return (refined, budget)
    }

    /// Simulates a token coin-transfer with `coins` as gas payment and returns
    /// the minimum SUI coin set that covers the resulting budget, paired with
    /// that budget.
    func simulateAndSelectTokenGas(
        sender: SuiAddress,
        tokenCoins: [SuiCoinObject],
        amount: UInt64,
        recipient: SuiAddress,
        gasPrice: UInt64,
        suiCoins: [SuiCoinObject],
        totalSUI: UInt64,
        coins: [SuiCoinObject]
    ) async throws -> (coins: [SuiCoinObject], budget: UInt64) {
        let coinsTotal = coins.reduce(UInt64(0)) { $0 &+ $1.balance }
        let capBudget = min(SuiTransactionBuilder.simulationBudget, coinsTotal)
        let simTx = makeCoinTransferBcs(
            sender: sender, tokenCoins: tokenCoins, amount: amount, recipient: recipient,
            gasCoins: coins.map(\.reference), gasOwner: sender, gasPrice: gasPrice,
            gasBudget: capBudget
        )
        let budget = try await simulatedBudget(transactionBcs: simTx)
        guard let refined = selectCoins(from: suiCoins, needed: budget) else {
            throw BlockchainTransactionBuilderError.insufficientFunds(
                reason: "need gas but \(sender.string) only has \(totalSUI) MIST SUI"
            )
        }
        return (refined, budget)
    }

    /// Builds the BCS bytes for an exact-amount token transfer, choosing
    /// the single-coin-split or multi-coin-merge-split shape depending on
    /// how many `tokenCoins` were selected.
    func makeCoinTransferBcs(
        sender: SuiAddress,
        tokenCoins: [SuiCoinObject],
        amount: UInt64,
        recipient: SuiAddress,
        gasCoins: [SuiObjectReference],
        gasOwner: SuiAddress,
        gasPrice: UInt64,
        gasBudget: UInt64
    ) -> Data {
        if tokenCoins.count == 1 {
            return UnsignedSingleCoinSplitTransfer(
                sender: sender,
                coinObject: tokenCoins[0].reference,
                amount: amount,
                recipient: recipient,
                gasPayment: gasCoins,
                gasOwner: gasOwner,
                gasPrice: gasPrice,
                gasBudget: gasBudget
            ).transactionDataBcs
        } else {
            return UnsignedMultiCoinMergeSplitTransfer(
                sender: sender,
                coinObjects: tokenCoins.map(\.reference),
                amount: amount,
                recipient: recipient,
                gasPayment: gasCoins,
                gasOwner: gasOwner,
                gasPrice: gasPrice,
                gasBudget: gasBudget
            ).transactionDataBcs
        }
    }

    /// Returns the smallest prefix of `coins` (sorted descending by balance)
    /// whose combined balance ≥ `needed`, or `nil` if the total is insufficient.
    func selectCoins(from coins: [SuiCoinObject], needed: UInt64) -> [SuiCoinObject]? {
        var selected: [SuiCoinObject] = []
        var accumulated = UInt64(0)
        for coin in coins {
            selected.append(coin)
            let (sum, overflow) = accumulated.addingReportingOverflow(coin.balance)
            accumulated = overflow ? .max : sum
            if accumulated >= needed { return selected }
        }
        return nil
    }

    /// Simulates `transactionBcs` and returns `max(1, grossFee × 2)`.
    ///
    /// The budget is based on ``FeeEstimate/grossFee`` (`computationCost +
    /// storageCost`) rather than the net ``FeeEstimate/estimatedFee``
    /// (`computationCost + storageCost − storageRebate`). The rebate is
    /// credited after the transaction executes, so the budget must cover the
    /// full gross cost — for merge/delete-heavy transactions the net can be
    /// far below the required budget.
    func simulatedBudget(transactionBcs: Data) async throws -> UInt64 {
        let estimate = try await client.estimateFee(for: FeeEstimateRequest(data: transactionBcs))
        let base = estimate.grossFee ?? estimate.estimatedFee ?? estimate.gasPrice
        return max(1, UInt64(base * 2))
    }
}

private extension Array where Element == BlockchainTransactionBuilderOptions {
    /// Extracts the first `.suiGasOverride` from the options array, or `nil`
    /// if none was supplied.
    var suiGasOverride: (budget: UInt64?, price: UInt64?)? {
        for option in self {
            if case let .suiGasOverride(budget, price) = option {
                return (budget, price)
            }
        }
        return nil
    }
}
