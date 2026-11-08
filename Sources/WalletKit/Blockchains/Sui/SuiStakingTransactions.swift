//
//  SuiStakingTransactions.swift
//  WalletKit
//
//  Created by Andrey Yurkevich on 08/11/2026.
//  Copyright © 2026 Reefr Wallet. All rights reserved.
//
//  Programmable transactions for native Sui staking (`0x3::sui_system`
//  and `0x3::staking_pool`). The system state object `0x5` is a shared
//  input; its initial shared version is 1 on every network. Command
//  results are referenced as `NestedResult(i, 0)`, as the official SDK does.

import Foundation

/// Where Sui's staking Move code lives.
public enum SuiStakingFramework {
    /// `0x5`, the `SuiSystemState` shared object.
    public static let systemStateObjectId = Data(repeating: 0, count: 31) + Data([0x05])
    /// `SuiSystemState`'s initial shared version.
    public static let systemStateInitialSharedVersion: UInt64 = 1
    /// Smallest amount that can be staked, and smallest stake that may remain after a split (1 SUI).
    public static let minimumStake: UInt64 = 1_000_000_000

    static let systemModule = "sui_system"
    static let stakingPoolModule = "staking_pool"
    static let addStakeFunction = "request_add_stake"
    static let splitFunction = "split"
    static let withdrawStakeFunction = "request_withdraw_stake"

    /// `0x3`, the `sui_system` package.
    static var systemPackage: SuiAddress {
        get throws { try SuiAddress(rawBytes: Data(repeating: 0, count: 31) + Data([0x03])) }
    }

    static var systemStateInput: SuiCallArg {
        .shared(objectId: systemStateObjectId, initialSharedVersion: systemStateInitialSharedVersion, isMutable: true)
    }
}

/// Gas and expiry fields every staking transaction carries.
public struct SuiStakingEnvelope: Sendable, Equatable {
    public let expirationEpoch: UInt64
    public let gasBudget: UInt64
    public let gasPayment: [SuiObjectReference]
    public let gasPrice: UInt64
    public let sender: SuiAddress

    public init(
        sender: SuiAddress,
        gasPayment: [SuiObjectReference],
        gasPrice: UInt64,
        gasBudget: UInt64,
        expirationEpoch: UInt64
    ) {
        self.sender = sender
        self.gasPayment = gasPayment
        self.gasPrice = gasPrice
        self.gasBudget = gasBudget
        self.expirationEpoch = expirationEpoch
    }
}

public enum SuiStakingTransactions {
    /// Splits `amount` off the gas coin and stakes it with `validator`.
    public static func stake(
        amount: UInt64, validator: SuiAddress, envelope: SuiStakingEnvelope
    ) throws -> SuiProgrammableTransaction {
        try make(
            inputs: [SuiStakingFramework.systemStateInput, .pure(BCS.u64(amount)), .pure(validator.rawBytes)],
            commands: [
                .splitCoins(.gasCoin, [.input(1)]),
                .moveCall(
                    package: SuiStakingFramework.systemPackage,
                    module: SuiStakingFramework.systemModule,
                    function: SuiStakingFramework.addStakeFunction,
                    arguments: [.input(0), .nestedResult(0, 0), .input(2)]
                )
            ],
            envelope: envelope
        )
    }

    /// Withdraws the whole `stakedSui` receipt; principal and rewards come back as SUI.
    public static func withdraw(
        stakedSui: SuiObjectReference, envelope: SuiStakingEnvelope
    ) throws -> SuiProgrammableTransaction {
        try make(
            inputs: [SuiStakingFramework.systemStateInput, .object(stakedSui)],
            commands: [
                .moveCall(
                    package: SuiStakingFramework.systemPackage,
                    module: SuiStakingFramework.systemModule,
                    function: SuiStakingFramework.withdrawStakeFunction,
                    arguments: [.input(0), .input(1)]
                )
            ],
            envelope: envelope
        )
    }

    /// Splits `amount` off `stakedSui` and withdraws only that part, in one transaction.
    public static func withdrawPartial(
        stakedSui: SuiObjectReference, amount: UInt64, envelope: SuiStakingEnvelope
    ) throws -> SuiProgrammableTransaction {
        try make(
            inputs: [SuiStakingFramework.systemStateInput, .object(stakedSui), .pure(BCS.u64(amount))],
            commands: [
                .moveCall(
                    package: SuiStakingFramework.systemPackage,
                    module: SuiStakingFramework.stakingPoolModule,
                    function: SuiStakingFramework.splitFunction,
                    arguments: [.input(1), .input(2)]
                ),
                .moveCall(
                    package: SuiStakingFramework.systemPackage,
                    module: SuiStakingFramework.systemModule,
                    function: SuiStakingFramework.withdrawStakeFunction,
                    arguments: [.input(0), .nestedResult(0, 0)]
                )
            ],
            envelope: envelope
        )
    }

    private static func make(
        inputs: [SuiCallArg], commands: [SuiCommand], envelope: SuiStakingEnvelope
    ) -> SuiProgrammableTransaction {
        SuiProgrammableTransaction(
            sender: envelope.sender,
            inputs: inputs,
            commands: commands,
            gasPayment: envelope.gasPayment,
            gasPrice: envelope.gasPrice,
            gasBudget: envelope.gasBudget,
            expiration: .epoch(envelope.expirationEpoch)
        )
    }
}
