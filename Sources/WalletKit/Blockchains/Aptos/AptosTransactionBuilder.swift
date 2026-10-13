//
//  AptosTransactionBuilder.swift
//  WalletKit
//
//  Copyright © 2026 Reefr Wallet. All rights reserved.
//

import BigInt
import Foundation

/// Builds BCS `RawTransaction` bytes for APT, Coin-standard, and Fungible
/// Asset transfers, sizing gas by simulation.
///
/// Token identifiers: `nil` or either form of APT for the native asset; a
/// Move type (`0x…::module::Name`) for a Coin; a metadata address for a
/// Fungible Asset.
public struct AptosTransactionBuilder: BlockchainTransactionBuilderProtocol {
    public typealias Address = AptosAddress

    /// `TransactionAuthenticator::SingleSender(NoAccountAuthenticator)`:
    /// simulation without the sender's public key.
    static let simulationAuthenticator = Data([4, 4])

    /// Per-transaction gas-unit ceiling used for simulation.
    static let simulationMaxGas: UInt64 = 200_000

    /// Seconds a built transaction stays valid, from the node's ledger time.
    static let expiration: UInt64 = 600

    private let client: AptosClient

    public init(client: AptosClient) {
        self.client = client
    }

    public func buildTransfer(
        sender: AptosAddress,
        recipient: AptosAddress,
        amount: BigUInt,
        token: String?,
        options: [BlockchainTransactionBuilderOptions]
    ) async throws -> Data {
        guard let amount = UInt64(exactly: amount) else {
            throw BlockchainTransactionBuilderError.amountTooLarge
        }

        let payload = try Self.payload(recipient: recipient, amount: amount, token: token)
        let isNative = token.map(AptosClient.isNativeAsset) ?? true
        let override = options.aptosGasOverride

        async let ledger = client.ledgerInfo()
        async let sequenceNumber = client.sequenceNumber(of: sender)
        async let nativeBalance = client.balance(of: sender, assetType: AptosClient.nativeCoinType)

        let gasUnitPrice = try await gasUnitPrice(override: override?.gasUnitPrice)
        let balance = try await nativeBalance
        let spendable: (partialValue: UInt64, overflow: Bool) = isNative
            ? balance.subtractingReportingOverflow(amount)
            : (balance, false)

        guard !spendable.overflow, spendable.partialValue > 0 else {
            throw BlockchainTransactionBuilderError.insufficientFunds(
                reason: "\(sender.string) has \(balance) octas, needs \(isNative ? amount : 0) plus gas"
            )
        }

        let affordableGas = spendable.partialValue / gasUnitPrice
        let info = try await ledger
        let sequence = try await sequenceNumber

        func rawTransaction(maxGasAmount: UInt64) -> AptosRawTransaction {
            AptosRawTransaction(
                sender: sender,
                sequenceNumber: sequence,
                payload: payload,
                maxGasAmount: maxGasAmount,
                gasUnitPrice: gasUnitPrice,
                expirationTimestampSecs: info.ledgerTimestamp / 1_000_000 + Self.expiration,
                chainId: info.chainId
            )
        }

        let maxGasAmount: UInt64
        if let overrideGas = override?.maxGasAmount {
            maxGasAmount = overrideGas
        } else {
            let simulated = rawTransaction(maxGasAmount: min(Self.simulationMaxGas, affordableGas))
            maxGasAmount = try await simulatedMaxGas(simulated, affordableGas: affordableGas)
        }

        guard maxGasAmount <= affordableGas else {
            throw BlockchainTransactionBuilderError.insufficientFunds(
                reason: "\(sender.string) can't cover \(maxGasAmount) gas units at \(gasUnitPrice) octas"
            )
        }

        return rawTransaction(maxGasAmount: maxGasAmount).bcs
    }

    static func payload(recipient: AptosAddress, amount: UInt64, token: String?) throws -> AptosEntryFunction {
        guard let token, !AptosClient.isNativeAsset(token) else {
            return .aptTransfer(to: recipient, amount: amount)
        }

        if token.contains("::") {
            return .coinTransfer(coinType: try MoveType(parsing: token), to: recipient, amount: amount)
        }

        guard let metadata = try? AptosAddress(chainString: token) else {
            throw BlockchainTransactionBuilderError.invalidToken(reason: "not a Coin type or metadata address: \(token)")
        }

        return .fungibleAssetTransfer(metadata: metadata, to: recipient, amount: amount)
    }

    private func gasUnitPrice(override: UInt64?) async throws -> UInt64 {
        let price: UInt64
        if let override {
            price = override
        } else {
            price = try await client.estimateGasPrice().estimate
        }

        guard price > 0 else {
            throw BlockchainTransactionBuilderError.gasSelectionFailed(reason: "gas unit price is zero")
        }

        return price
    }

    /// Simulates `transaction` and returns twice the gas it used, capped by
    /// what the sender can afford.
    private func simulatedMaxGas(_ transaction: AptosRawTransaction, affordableGas: UInt64) async throws -> UInt64 {
        let simulation = try await client.simulate(
            rawTransaction: transaction.bcs,
            authenticator: Self.simulationAuthenticator
        )

        guard simulation.success else {
            throw Self.simulationError(simulation.vmStatus)
        }

        let (doubled, overflow) = simulation.gasUsed.multipliedReportingOverflow(by: 2)
        return max(simulation.gasUsed, min(overflow ? .max : doubled, affordableGas))
    }

    private static func simulationError(_ vmStatus: String) -> BlockchainTransactionBuilderError {
        let insufficient = ["INSUFFICIENT_BALANCE", "EINSUFFICIENT_BALANCE", "ECOIN_STORE_NOT_PUBLISHED"]

        if insufficient.contains(where: vmStatus.contains) {
            return .insufficientFunds(reason: vmStatus)
        }

        return .gasSelectionFailed(reason: "simulation failed: \(vmStatus)")
    }
}

private extension Array where Element == BlockchainTransactionBuilderOptions {
    var aptosGasOverride: (maxGasAmount: UInt64?, gasUnitPrice: UInt64?)? {
        for option in self {
            if case let .aptosGasOverride(maxGasAmount, gasUnitPrice) = option {
                return (maxGasAmount, gasUnitPrice)
            }
        }

        return nil
    }
}
