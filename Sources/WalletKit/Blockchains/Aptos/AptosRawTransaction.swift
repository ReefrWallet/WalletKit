//
//  AptosRawTransaction.swift
//  WalletKit
//
//  Copyright © 2026 Reefr Wallet. All rights reserved.
//

import Foundation

/// An Aptos entry-function call, e.g. `0x1::aptos_account::transfer`.
public struct AptosEntryFunction: Equatable, Sendable {
    public let module: AptosAddress
    public let moduleName: String
    public let functionName: String
    public let typeArguments: [MoveType]
    /// Each argument's own BCS encoding.
    public let arguments: [Data]

    public init(
        module: AptosAddress,
        moduleName: String,
        functionName: String,
        typeArguments: [MoveType] = [],
        arguments: [Data]
    ) {
        self.module = module
        self.moduleName = moduleName
        self.functionName = functionName
        self.typeArguments = typeArguments
        self.arguments = arguments
    }

    /// `module::function`, e.g. `0x1::aptos_account::transfer`.
    public var identifier: String {
        "\(module.string)::\(moduleName)::\(functionName)"
    }

    /// BCS `TransactionPayload::EntryFunction`.
    var payloadBcs: Data {
        Data([2]) + module.rawBytes + BCS.string(moduleName) + BCS.string(functionName)
            + BCS.uleb128(typeArguments.count) + typeArguments.reduce(Data()) { $0 + $1.bcs }
            + BCS.uleb128(arguments.count) + arguments.reduce(Data()) { $0 + BCS.byteVector($1) }
    }
}

/// An unsigned Aptos `RawTransaction` with an entry-function payload.
public struct AptosRawTransaction: Equatable, Sendable {
    public let sender: AptosAddress
    public let sequenceNumber: UInt64
    public let payload: AptosEntryFunction
    public let maxGasAmount: UInt64
    public let gasUnitPrice: UInt64
    public let expirationTimestampSecs: UInt64
    public let chainId: UInt8

    public init(
        sender: AptosAddress,
        sequenceNumber: UInt64,
        payload: AptosEntryFunction,
        maxGasAmount: UInt64,
        gasUnitPrice: UInt64,
        expirationTimestampSecs: UInt64,
        chainId: UInt8
    ) {
        self.sender = sender
        self.sequenceNumber = sequenceNumber
        self.payload = payload
        self.maxGasAmount = maxGasAmount
        self.gasUnitPrice = gasUnitPrice
        self.expirationTimestampSecs = expirationTimestampSecs
        self.chainId = chainId
    }

    /// BCS `RawTransaction` bytes, ready for ``AptosPKeySigner/sign(transaction:)``.
    public var bcs: Data {
        sender.rawBytes + BCS.u64(sequenceNumber) + payload.payloadBcs
            + BCS.u64(maxGasAmount) + BCS.u64(gasUnitPrice) + BCS.u64(expirationTimestampSecs)
            + Data([chainId])
    }

    /// Decodes BCS `RawTransaction` bytes, fail-closed: only entry-function
    /// payloads are accepted, every length is bounded, and the input must be
    /// consumed exactly.
    ///
    /// - Throws: ``BlockchainClientError/decodingFailed(reason:)``.
    public init(bcs: Data) throws {
        var reader = BCSReader(bcs)

        do {
            sender = try AptosAddress(rawBytes: Data(try reader.bytes(32)))
            sequenceNumber = try reader.u64()

            guard try reader.uleb128() == 2 else {
                throw BCSReader.failure("only entry-function payloads are supported")
            }

            let module = try AptosAddress(rawBytes: Data(try reader.bytes(32)))
            let moduleName = try MoveType.identifier(&reader)
            let functionName = try MoveType.identifier(&reader)
            let typeArguments = try (0..<reader.length(limit: 32)).map { _ in try MoveType(bcs: &reader) }
            let arguments = try (0..<reader.length(limit: 256)).map { _ in Data(try reader.byteVector()) }

            payload = AptosEntryFunction(
                module: module,
                moduleName: moduleName,
                functionName: functionName,
                typeArguments: typeArguments,
                arguments: arguments
            )

            maxGasAmount = try reader.u64()
            gasUnitPrice = try reader.u64()
            expirationTimestampSecs = try reader.u64()
            chainId = try reader.u8()
            try reader.expectEnd()
        } catch let error as BlockchainClientError {
            throw error
        } catch {
            throw BCSReader.failure("\(error)")
        }
    }

    /// Reads the gas fields from BCS `RawTransaction` bytes. They're fixed-width
    /// and follow the payload: `max_gas_amount`, `gas_unit_price`, expiry, chain ID.
    ///
    /// - Throws: ``BlockchainClientError/decodingFailed(reason:)`` if `bcs` is too short.
    public static func gasParameters(of bcs: Data) throws -> (maxGasAmount: UInt64, gasUnitPrice: UInt64) {
        // sender + sequence number + payload variant + gas fields + expiry + chain ID.
        guard bcs.count >= 32 + 8 + 1 + 8 + 8 + 8 + 1 else {
            throw BlockchainClientError.decodingFailed(reason: "Aptos raw transaction is too short")
        }

        let trailer = bcs.suffix(25)
        let u64 = { (offset: Int) in
            trailer.dropFirst(offset).prefix(8).reversed().reduce(UInt64(0)) { $0 << 8 | UInt64($1) }
        }

        return (u64(0), u64(8))
    }

    /// `max_gas_amount × gas_unit_price`: the most the transaction can charge.
    public static func maxFee(of bcs: Data) throws -> UInt64 {
        let (maxGasAmount, gasUnitPrice) = try gasParameters(of: bcs)
        let (fee, overflow) = maxGasAmount.multipliedReportingOverflow(by: gasUnitPrice)
        return overflow ? .max : fee
    }
}

public extension AptosEntryFunction {
    private static let framework = try! AptosAddress(string: "0x1") // swiftlint:disable:this force_try

    /// `0x1::aptos_account::transfer` — moves APT, creating `recipient`'s
    /// account if needed.
    static func aptTransfer(to recipient: AptosAddress, amount: UInt64) -> AptosEntryFunction {
        AptosEntryFunction(
            module: framework,
            moduleName: "aptos_account",
            functionName: "transfer",
            arguments: [recipient.rawBytes, BCS.u64(amount)]
        )
    }

    /// `0x1::aptos_account::transfer_coins<T>` for a Coin-standard `coinType`.
    static func coinTransfer(coinType: MoveType, to recipient: AptosAddress, amount: UInt64) -> AptosEntryFunction {
        AptosEntryFunction(
            module: framework,
            moduleName: "aptos_account",
            functionName: "transfer_coins",
            typeArguments: [coinType],
            arguments: [recipient.rawBytes, BCS.u64(amount)]
        )
    }

    /// `0x1::primary_fungible_store::transfer<Metadata>` for a Fungible Asset.
    static func fungibleAssetTransfer(
        metadata: AptosAddress,
        to recipient: AptosAddress,
        amount: UInt64
    ) -> AptosEntryFunction {
        AptosEntryFunction(
            module: framework,
            moduleName: "primary_fungible_store",
            functionName: "transfer",
            typeArguments: [
                .structTag(address: framework.rawBytes, module: "fungible_asset", name: "Metadata", typeArguments: [])
            ],
            arguments: [metadata.rawBytes, recipient.rawBytes, BCS.u64(amount)]
        )
    }
}
