//
//  SuiProgrammableTransaction.swift
//  WalletKit
//
//  Created by Andrey Yurkevich on 08/11/2026.
//  Copyright © 2026 Reefr Wallet. All rights reserved.
//
//  A general BCS writer for `TransactionData::V1` Programmable Transaction
//  Blocks: Move calls, shared-object inputs, `Result` arguments and epoch
//  expiry. Used for staking; the fixed-shape transfer encoders in
//  SuiUnsignedTransactions.swift are unchanged.

import Foundation

/// A PTB command argument.
public enum SuiArgument: Sendable, Equatable {
    case gasCoin
    case input(UInt16)
    case nestedResult(UInt16, UInt16)
    case result(UInt16)

    fileprivate var bcs: Data {
        switch self {
        case .gasCoin:
            Data([0x00])
        case let .input(index):
            Data([0x01]) + BCS.u16(index)
        case let .result(index):
            Data([0x02]) + BCS.u16(index)
        case let .nestedResult(index, subIndex):
            Data([0x03]) + BCS.u16(index) + BCS.u16(subIndex)
        }
    }
}

/// A PTB input.
public enum SuiCallArg: Sendable, Equatable {
    case object(SuiObjectReference)
    case pure(Data)
    case shared(objectId: Data, initialSharedVersion: UInt64, isMutable: Bool)

    fileprivate var bcs: Data {
        switch self {
        case let .pure(bytes):
            return Data([0x00]) + BCS.byteVector(bytes)
        case let .object(reference):
            return Data([0x01, 0x00]) + reference.objectId + BCS.u64(reference.version)
                + BCS.byteVector(reference.digest)
        case let .shared(objectId, initialSharedVersion, isMutable):
            return Data([0x01, 0x01]) + objectId + BCS.u64(initialSharedVersion) + Data([isMutable ? 1 : 0])
        }
    }
}

/// A PTB command. Move calls here are non-generic (no type arguments).
public enum SuiCommand: Sendable, Equatable {
    case mergeCoins(SuiArgument, [SuiArgument])
    case moveCall(package: SuiAddress, module: String, function: String, arguments: [SuiArgument])
    case splitCoins(SuiArgument, [SuiArgument])
    case transferObjects([SuiArgument], SuiArgument)

    fileprivate var bcs: Data {
        switch self {
        case let .moveCall(package, module, function, arguments):
            return Data([0x00]) + package.rawBytes + BCS.string(module) + BCS.string(function)
                + BCS.uleb128(0) + Self.vector(arguments)
        case let .transferObjects(objects, destination):
            return Data([0x01]) + Self.vector(objects) + destination.bcs
        case let .splitCoins(coin, amounts):
            return Data([0x02]) + coin.bcs + Self.vector(amounts)
        case let .mergeCoins(target, sources):
            return Data([0x03]) + target.bcs + Self.vector(sources)
        }
    }

    private static func vector(_ arguments: [SuiArgument]) -> Data {
        arguments.reduce(BCS.uleb128(arguments.count)) { $0 + $1.bcs }
    }
}

/// When a transaction stops being executable.
public enum SuiTransactionExpiration: Sendable, Equatable {
    /// Executable in this epoch and the one before it, never after.
    case epoch(UInt64)
    case none

    fileprivate var bcs: Data {
        switch self {
        case .none: Data([0x00])
        case let .epoch(epoch): Data([0x01]) + BCS.u64(epoch)
        }
    }
}

/// An unsigned `TransactionData::V1` carrying a programmable transaction.
public struct SuiProgrammableTransaction: Sendable, Equatable {
    public let commands: [SuiCommand]
    public let expiration: SuiTransactionExpiration
    public let gasBudget: UInt64
    public let gasOwner: SuiAddress
    public let gasPayment: [SuiObjectReference]
    public let gasPrice: UInt64
    public let inputs: [SuiCallArg]
    public let sender: SuiAddress

    public init(
        sender: SuiAddress,
        inputs: [SuiCallArg],
        commands: [SuiCommand],
        gasPayment: [SuiObjectReference],
        gasOwner: SuiAddress? = nil,
        gasPrice: UInt64,
        gasBudget: UInt64,
        expiration: SuiTransactionExpiration
    ) {
        self.sender = sender
        self.inputs = inputs
        self.commands = commands
        self.gasPayment = gasPayment
        self.gasOwner = gasOwner ?? sender
        self.gasPrice = gasPrice
        self.gasBudget = gasBudget
        self.expiration = expiration
    }

    /// BCS-encoded `TransactionData::V1`, the exact bytes that get signed.
    public var transactionDataBcs: Data {
        var data = Data([0x00, 0x00]) // V1, ProgrammableTransaction
        data.append(BCS.uleb128(inputs.count))
        for input in inputs {
            data.append(input.bcs)
        }

        data.append(BCS.uleb128(commands.count))
        for command in commands {
            data.append(command.bcs)
        }

        data.append(sender.rawBytes)
        data.append(BCS.uleb128(gasPayment.count))
        for reference in gasPayment {
            data.append(reference.objectId + BCS.u64(reference.version) + BCS.byteVector(reference.digest))
        }

        data.append(gasOwner.rawBytes)
        data.append(BCS.u64(gasPrice))
        data.append(BCS.u64(gasBudget))
        data.append(expiration.bcs)
        return data
    }

    /// The transaction digest, Blake2b-256 over `"TransactionData::"` and the BCS bytes.
    public var digest: Data { Self.digest(ofTransactionData: transactionDataBcs) }

    /// The digest Sui assigns to `transactionData`.
    public static func digest(ofTransactionData transactionData: Data) -> Data {
        Blake2b256.hash(Data("TransactionData::".utf8) + transactionData)
    }
}
