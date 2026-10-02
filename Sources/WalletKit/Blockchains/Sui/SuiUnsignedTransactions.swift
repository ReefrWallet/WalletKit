//
//  SuiUnsignedTransactions.swift
//  WalletKit
//
//  Created by Andrey Yurkevich on 28/08/2026.
//  Copyright © 2026 Reefr Wallet. All rights reserved.
//
//  BCS-encoded Programmable Transaction Block (PTB) shapes for Sui.
//  Every struct below produces a raw `TransactionData::V1` payload that
//  ``SuiPKeySigner/sign(transaction:)`` accepts directly.
//
//  Byte layouts were reverse-engineered from decoded `sui-tx.json` vectors
//  and cross-checked in `SuiTransactionDataTests.swift` before ever being
//  trusted against a live node.

import Foundation

// MARK: - Native SUI transfer (split gas coin)

/// An unsigned "split the gas coin and transfer the pieces" Programmable
/// Transaction Block — the canonical wallet-transfer PTB for native SUI.
///
/// The PTB structure:
/// - inputs: one `CallArg::Pure(u64)` per transfer amount, then one
///   `CallArg::Pure(address)` per recipient.
/// - commands: `SplitCoins(GasCoin, [amounts…])`, followed by one
///   `TransferObjects([piece], recipient)` per transfer.
///
/// For a single transfer the split coin is referenced as `Result(0)`; for
/// multiple transfers, each piece is `NestedResult(0, i)`.
public struct UnsignedSuiTransaction: Sendable {
    public let sender: SuiAddress
    /// The transfers to execute: one `(recipient, amount)` pair each.
    /// Amounts are in MIST (SUI's smallest unit).
    public let transfers: [(recipient: SuiAddress, amount: UInt64)]
    /// The SUI coin(s) to use for gas and as the split source.
    public let gasPayment: [SuiObjectReference]
    public let gasOwner: SuiAddress
    /// Gas price in MIST per gas unit.
    public let gasPrice: UInt64
    /// Maximum gas cost in MIST.
    public let gasBudget: UInt64

    public init(
        sender: SuiAddress,
        transfers: [(recipient: SuiAddress, amount: UInt64)],
        gasPayment: [SuiObjectReference],
        gasOwner: SuiAddress,
        gasPrice: UInt64,
        gasBudget: UInt64
    ) {
        self.sender = sender
        self.transfers = transfers
        self.gasPayment = gasPayment
        self.gasOwner = gasOwner
        self.gasPrice = gasPrice
        self.gasBudget = gasBudget
    }

    /// BCS-encoded `TransactionData::V1` with the gas-coin-split PTB.
    public var transactionDataBcs: Data {
        var data = Data()
        data.append(0x00) // TransactionData::V1
        data.append(0x00) // TransactionKind::ProgrammableTransaction

        let amountInputs = transfers.map { BCS.byteVector(BCS.u64($0.amount)) }

        let recipientInputs = transfers.map { BCS.byteVector($0.recipient.rawBytes) }

        let inputs = amountInputs + recipientInputs
        data.append(BCS.uleb128(inputs.count))
        for input in inputs {
            data.append(0x00) // CallArg::Pure
            data.append(input)
        }

        // SplitCoins + one TransferObjects per transfer
        data.append(BCS.uleb128(1 + transfers.count))

        data.append(0x02) // Command::SplitCoins
        data.append(0x00) // Argument::GasCoin
        data.append(BCS.uleb128(transfers.count))
        for index in 0..<transfers.count {
            data.append(0x01) // Argument::Input
            data.append(BCS.u16(UInt16(index)))
        }

        for index in transfers.indices {
            data.append(0x01) // Command::TransferObjects
            data.append(BCS.uleb128(1))
            if transfers.count == 1 {
                data.append(0x02) // Argument::Result
                data.append(BCS.u16(0))
            } else {
                data.append(0x03) // Argument::NestedResult
                data.append(BCS.u16(0))
                data.append(BCS.u16(UInt16(index)))
            }

            data.append(0x01) // Argument::Input, the matching recipient
            data.append(BCS.u16(UInt16(transfers.count + index)))
        }

        data.append(sender.rawBytes)
        appendGasData(&data, gasPayment: gasPayment, gasOwner: gasOwner, gasPrice: gasPrice, gasBudget: gasBudget)
        data.append(0x00) // TransactionExpiration::None

        return data
    }
}

// MARK: - Whole-coin-object transfer

/// An unsigned "transfer an owned `Coin<T>` object" Programmable Transaction
/// Block — the PTB shape for sending an entire coin object (e.g. a USDC or
/// other token that already exists as an owned object) without splitting.
///
/// The PTB has two inputs and one command:
/// - Input 0: `CallArg::Object(ImmOrOwned(coinObject))`
/// - Input 1: `CallArg::Pure(recipient.rawBytes)`
/// - Command 0: `TransferObjects([Input(0)], Input(1))`
///
/// The coin object and the gas payment object **must be different objects**.
public struct UnsignedCoinObjectTransfer: Sendable {
    public let sender: SuiAddress
    /// The `Coin<T>` object to transfer in its entirety.
    public let coinObject: SuiObjectReference
    public let recipient: SuiAddress
    /// SUI coin(s) used to pay gas — must differ from `coinObject`.
    public let gasPayment: [SuiObjectReference]
    public let gasOwner: SuiAddress
    public let gasPrice: UInt64
    public let gasBudget: UInt64

    public init(
        sender: SuiAddress,
        coinObject: SuiObjectReference,
        recipient: SuiAddress,
        gasPayment: [SuiObjectReference],
        gasOwner: SuiAddress,
        gasPrice: UInt64,
        gasBudget: UInt64
    ) {
        self.sender = sender
        self.coinObject = coinObject
        self.recipient = recipient
        self.gasPayment = gasPayment
        self.gasOwner = gasOwner
        self.gasPrice = gasPrice
        self.gasBudget = gasBudget
    }

    /// BCS-encoded `TransactionData::V1` with the coin-object-transfer PTB.
    public var transactionDataBcs: Data {
        var data = Data()
        data.append(0x00) // TransactionData::V1
        data.append(0x00) // TransactionKind::ProgrammableTransaction

        // inputs: [Object(ImmOrOwned(coinObject)), Pure(recipient)]
        data.append(BCS.uleb128(2))
        appendImmOrOwned(&data, reference: coinObject)
        data.append(0x00) // CallArg::Pure
        data.append(BCS.byteVector(recipient.rawBytes))

        // commands: [TransferObjects([Input(0)], Input(1))]
        data.append(BCS.uleb128(1))
        data.append(0x01) // Command::TransferObjects
        data.append(BCS.uleb128(1))
        data.append(0x01) // Argument::Input
        data.append(BCS.u16(0)) // Input(0) = coinObject
        data.append(0x01) // Argument::Input
        data.append(BCS.u16(1)) // Input(1) = recipient

        data.append(sender.rawBytes)
        appendGasData(&data, gasPayment: gasPayment, gasOwner: gasOwner, gasPrice: gasPrice, gasBudget: gasBudget)
        data.append(0x00) // TransactionExpiration::None

        return data
    }
}

// MARK: - Exact-amount split from a single coin

/// An unsigned "split an exact amount from a single coin, transfer the
/// piece" Programmable Transaction Block.
///
/// Use this when the sender owns one `Coin<T>` with a balance at least
/// `amount`. The PTB structure:
/// - Input 0: `CallArg::Object(ImmOrOwned(coinObject))` — the coin to split.
/// - Input 1: `CallArg::Pure(amount as u64 LE)` — the amount.
/// - Input 2: `CallArg::Pure(recipient.rawBytes)` — the destination.
/// - Command 0: `SplitCoins(Input(0), [Input(1)])` → `Result(0)` = new coin.
/// - Command 1: `TransferObjects([Result(0)], Input(2))`.
///
/// The coin object and the gas payment objects **must be different objects**;
/// pass a separate SUI coin in `gasPayment`.
public struct UnsignedSingleCoinSplitTransfer: Sendable {
    public let sender: SuiAddress
    /// The `Coin<T>` to split from; must have balance ≥ `amount`.
    public let coinObject: SuiObjectReference
    /// The amount to split off and transfer, in the coin's smallest unit.
    public let amount: UInt64
    public let recipient: SuiAddress
    /// SUI coin(s) used to pay gas — must differ from `coinObject`.
    public let gasPayment: [SuiObjectReference]
    public let gasOwner: SuiAddress
    public let gasPrice: UInt64
    public let gasBudget: UInt64

    public init(
        sender: SuiAddress,
        coinObject: SuiObjectReference,
        amount: UInt64,
        recipient: SuiAddress,
        gasPayment: [SuiObjectReference],
        gasOwner: SuiAddress,
        gasPrice: UInt64,
        gasBudget: UInt64
    ) {
        self.sender = sender
        self.coinObject = coinObject
        self.amount = amount
        self.recipient = recipient
        self.gasPayment = gasPayment
        self.gasOwner = gasOwner
        self.gasPrice = gasPrice
        self.gasBudget = gasBudget
    }

    /// BCS-encoded `TransactionData::V1` with the single-coin split PTB.
    public var transactionDataBcs: Data {
        var data = Data()
        data.append(0x00) // TransactionData::V1
        data.append(0x00) // TransactionKind::ProgrammableTransaction

        // inputs: [Object(ImmOrOwned(coinObject)), Pure(amount), Pure(recipient)]
        data.append(BCS.uleb128(3))
        appendImmOrOwned(&data, reference: coinObject)
        data.append(0x00) // CallArg::Pure
        data.append(BCS.byteVector(BCS.u64(amount)))
        data.append(0x00) // CallArg::Pure
        data.append(BCS.byteVector(recipient.rawBytes))

        // commands: [SplitCoins(Input(0), [Input(1)]), TransferObjects([Result(0)], Input(2))]
        data.append(BCS.uleb128(2))

        data.append(0x02) // Command::SplitCoins
        data.append(0x01) // Argument::Input
        data.append(BCS.u16(0)) // Input(0) = coinObject
        data.append(BCS.uleb128(1)) // one split amount
        data.append(0x01) // Argument::Input
        data.append(BCS.u16(1)) // Input(1) = amount

        data.append(0x01) // Command::TransferObjects
        data.append(BCS.uleb128(1))
        data.append(0x02) // Argument::Result
        data.append(BCS.u16(0)) // Result(0) = the split piece
        data.append(0x01) // Argument::Input
        data.append(BCS.u16(2)) // Input(2) = recipient

        data.append(sender.rawBytes)
        appendGasData(&data, gasPayment: gasPayment, gasOwner: gasOwner, gasPrice: gasPrice, gasBudget: gasBudget)
        data.append(0x00) // TransactionExpiration::None

        return data
    }
}

// MARK: - Exact-amount split from merged coins

/// An unsigned "merge N coins, split an exact amount, transfer the piece"
/// Programmable Transaction Block.
///
/// Use this when the sender owns multiple `Coin<T>` objects whose combined
/// balance covers `amount`. The PTB structure (N = number of coins):
/// - Inputs 0…N−1: `CallArg::Object(ImmOrOwned(coins[i]))`.
/// - Input N: `CallArg::Pure(amount as u64 LE)`.
/// - Input N+1: `CallArg::Pure(recipient.rawBytes)`.
/// - Command 0: `MergeCoins(Input(0), [Input(1), …, Input(N−1)])`.
/// - Command 1: `SplitCoins(Input(0), [Input(N)])` → `Result(1)`.
/// - Command 2: `TransferObjects([Result(1)], Input(N+1))`.
///
/// All `coinObjects` are merged into the first one (`coins[0]`) before
/// splitting. The `gasPayment` SUI coins **must not overlap** with
/// `coinObjects`; pass separate SUI coins. Requires `coinObjects.count ≥ 2`.
public struct UnsignedMultiCoinMergeSplitTransfer: Sendable {
    public let sender: SuiAddress
    /// The `Coin<T>` objects to merge; must have combined balance ≥ `amount`.
    /// `coins[0]` is the merge target; all others are merged into it.
    /// Must contain at least 2 elements.
    public let coinObjects: [SuiObjectReference]
    /// The amount to split off and transfer, in the coin's smallest unit.
    public let amount: UInt64
    public let recipient: SuiAddress
    /// SUI coin(s) used to pay gas — must not overlap with `coinObjects`.
    public let gasPayment: [SuiObjectReference]
    public let gasOwner: SuiAddress
    public let gasPrice: UInt64
    public let gasBudget: UInt64

    public init(
        sender: SuiAddress,
        coinObjects: [SuiObjectReference],
        amount: UInt64,
        recipient: SuiAddress,
        gasPayment: [SuiObjectReference],
        gasOwner: SuiAddress,
        gasPrice: UInt64,
        gasBudget: UInt64
    ) {
        precondition(coinObjects.count >= 2, "UnsignedMultiCoinMergeSplitTransfer requires at least 2 coin objects")
        self.sender = sender
        self.coinObjects = coinObjects
        self.amount = amount
        self.recipient = recipient
        self.gasPayment = gasPayment
        self.gasOwner = gasOwner
        self.gasPrice = gasPrice
        self.gasBudget = gasBudget
    }

    /// BCS-encoded `TransactionData::V1` with the merge+split PTB.
    public var transactionDataBcs: Data {
        let n = coinObjects.count
        var data = Data()
        data.append(0x00) // TransactionData::V1
        data.append(0x00) // TransactionKind::ProgrammableTransaction

        // inputs: [coins[0], coins[1], ..., coins[n-1], Pure(amount), Pure(recipient)]
        data.append(BCS.uleb128(n + 2))
        for coin in coinObjects {
            appendImmOrOwned(&data, reference: coin)
        }

        data.append(0x00) // CallArg::Pure
        data.append(BCS.byteVector(BCS.u64(amount)))
        data.append(0x00) // CallArg::Pure
        data.append(BCS.byteVector(recipient.rawBytes))

        // commands: [MergeCoins, SplitCoins, TransferObjects]
        data.append(BCS.uleb128(3))

        // Command 0: MergeCoins(Input(0), [Input(1), ..., Input(n-1)])
        data.append(0x03) // Command::MergeCoins
        data.append(0x01) // Argument::Input
        data.append(BCS.u16(0)) // Input(0) = target coin
        data.append(BCS.uleb128(n - 1)) // number of source coins
        for i in 1..<n {
            data.append(0x01) // Argument::Input
            data.append(BCS.u16(UInt16(i)))
        }

        // Command 1: SplitCoins(Input(0), [Input(n)])  → Result(1)
        data.append(0x02) // Command::SplitCoins
        data.append(0x01) // Argument::Input
        data.append(BCS.u16(0)) // Input(0) = merged target coin
        data.append(BCS.uleb128(1)) // one split amount
        data.append(0x01) // Argument::Input
        data.append(BCS.u16(UInt16(n))) // Input(n) = amount

        // Command 2: TransferObjects([Result(1)], Input(n+1))
        data.append(0x01) // Command::TransferObjects
        data.append(BCS.uleb128(1))
        data.append(0x02) // Argument::Result
        data.append(BCS.u16(1)) // Result(1) = the split piece from command 1
        data.append(0x01) // Argument::Input
        data.append(BCS.u16(UInt16(n + 1))) // Input(n+1) = recipient

        data.append(sender.rawBytes)
        appendGasData(&data, gasPayment: gasPayment, gasOwner: gasOwner, gasPrice: gasPrice, gasBudget: gasBudget)
        data.append(0x00) // TransactionExpiration::None

        return data
    }
}

// MARK: - Shared encoding helpers

/// Appends a `CallArg::Object(ObjectArg::ImmOrOwned(reference))` to `data`.
private func appendImmOrOwned(_ data: inout Data, reference: SuiObjectReference) {
    data.append(0x01) // CallArg::Object
    data.append(0x00) // ObjectArg::ImmOrOwned
    data.append(reference.objectId)
    data.append(BCS.u64(reference.version))
    data.append(BCS.byteVector(reference.digest))
}

/// Appends the BCS `GasData` block — payment references, owner, price,
/// budget — shared by all PTB shapes.
private func appendGasData(
    _ data: inout Data,
    gasPayment: [SuiObjectReference],
    gasOwner: SuiAddress,
    gasPrice: UInt64,
    gasBudget: UInt64
) {
    data.append(BCS.uleb128(gasPayment.count))
    for reference in gasPayment {
        data.append(reference.objectId)
        data.append(BCS.u64(reference.version))
        data.append(BCS.byteVector(reference.digest))
    }

    data.append(gasOwner.rawBytes)
    data.append(BCS.u64(gasPrice))
    data.append(BCS.u64(gasBudget))
}
