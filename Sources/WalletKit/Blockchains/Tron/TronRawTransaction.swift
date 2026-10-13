//
//  TronRawTransaction.swift
//  WalletKit
//
//  Created by Andrey Yurkevich on 13/10/2026.
//  Copyright © 2026 Reefr Wallet. All rights reserved.
//

import CryptoKit
import Foundation
import WalletKitRust

/// A fail-closed decoder for a Tron `Transaction.raw` protobuf — the
/// `raw_data_hex` bytes a Tron signature covers (`sha256(raw) == txID`).
///
/// Accepts exactly one `TransferContract` or `TriggerSmartContract` with
/// the default permission. Rejects every other contract type, multi-sig
/// permission ids, `auths`/`scripts`, TRC-10 call values, unknown or
/// repeated fields, wire-type mismatches, negative `int64`s and trailing
/// bytes, so what is previewed is exactly what gets signed.
public struct TronRawTransaction: Equatable, Sendable {
    public enum Contract: Equatable, Sendable {
        case transfer(owner: TronAddress, to: TronAddress, amount: UInt64)
        case triggerSmartContract(owner: TronAddress, contract: TronAddress, callValue: UInt64, data: Data)

        public var owner: TronAddress {
            switch self {
            case let .transfer(owner, _, _), let .triggerSmartContract(owner, _, _, _):
                owner
            }
        }
    }

    public let contract: Contract
    /// Milliseconds since the epoch.
    public let expiration: UInt64
    /// Energy cost cap in SUN (`TriggerSmartContract` only, in practice).
    public let feeLimit: UInt64?
    /// The optional `data` memo.
    public let memo: Data?
    /// The exact bytes that get signed.
    public let rawBytes: Data
    public let refBlockBytes: Data
    public let refBlockHash: Data
    public let refBlockNum: UInt64?
    /// Milliseconds since the epoch.
    public let timestamp: UInt64?

    /// `sha256(rawBytes)` — the transaction id.
    public var txId: Data {
        Data(SHA256.hash(data: rawBytes))
    }

    /// Decodes `rawBytes`, throwing ``BlockchainClientError/decodingFailed(reason:)``
    /// for anything outside the supported subset.
    public init(rawBytes: Data) throws {
        let fields = try ProtoFields(rawBytes, allowed: [
            1: .bytes, 3: .varint, 4: .bytes, 8: .varint, 10: .bytes, 11: .bytes, 14: .varint, 18: .varint
        ])

        let refBlockBytes = try fields.requiredBytes(1)
        let refBlockHash = try fields.requiredBytes(4)
        guard refBlockBytes.count == 2, refBlockHash.count == 8 else {
            throw Self.invalid("unexpected reference block length")
        }

        self.rawBytes = rawBytes
        self.refBlockBytes = refBlockBytes
        self.refBlockHash = refBlockHash
        refBlockNum = try fields.optionalInt64(3)
        expiration = try fields.requiredInt64(8)
        memo = fields.optionalBytes(10)
        contract = try Self.decodeContract(try fields.requiredBytes(11))
        timestamp = try fields.optionalInt64(14)
        feeLimit = try fields.optionalInt64(18)
    }

    /// The TronGrid-shaped `{txID, raw_data, raw_data_hex}` JSON both
    /// ``TronPKeySigner`` and ``TronTrezorSigner`` accept, built from the
    /// decoded fields rather than any dapp-supplied JSON.
    public func signingEnvelope() throws -> Data {
        var rawData: [String: Any] = [
            "contract": [contractJSON],
            "expiration": expiration,
            "ref_block_bytes": refBlockBytes.bareHex,
            "ref_block_hash": refBlockHash.bareHex,
            "timestamp": timestamp ?? 0
        ]

        if let feeLimit {
            rawData["fee_limit"] = feeLimit
        }

        if let memo {
            rawData["data"] = memo.bareHex
        }

        if let refBlockNum {
            rawData["ref_block_num"] = refBlockNum
        }

        return try JSONSerialization.data(
            withJSONObject: ["raw_data": rawData, "raw_data_hex": rawBytes.bareHex, "txID": txId.bareHex],
            options: [.sortedKeys]
        )
    }

    /// Whether ``TronTrezorSigner`` would sign exactly ``rawBytes``: Trezor
    /// signs its own re-serialization of the envelope's fields, which
    /// drops anything it doesn't model.
    public var isTrezorReproducible: Bool {
        guard
            let envelope = try? signingEnvelope(),
            let json = String(bytes: envelope, encoding: .utf8)
        else {
            return false
        }

        return (try? tronRawData(transaction: json)) == rawBytes
    }

    private var contractJSON: [String: Any] {
        switch contract {
        case let .transfer(owner, to, amount):
            return [
                "parameter": [
                    "type_url": Self.transferTypeURL,
                    "value": [
                        "amount": amount,
                        "owner_address": owner.rawBytes.bareHex,
                        "to_address": to.rawBytes.bareHex
                    ]
                ],
                "type": "TransferContract"
            ]
        case let .triggerSmartContract(owner, contract, callValue, data):
            var value: [String: Any] = [
                "contract_address": contract.rawBytes.bareHex,
                "data": data.bareHex,
                "owner_address": owner.rawBytes.bareHex
            ]

            if callValue > 0 {
                value["call_value"] = callValue
            }

            return ["parameter": ["type_url": Self.triggerTypeURL, "value": value], "type": "TriggerSmartContract"]
        }
    }
}

// MARK: - Contract decoding

private extension TronRawTransaction {
    static let transferTypeURL = "type.googleapis.com/protocol.TransferContract"
    static let triggerTypeURL = "type.googleapis.com/protocol.TriggerSmartContract"

    static func decodeContract(_ bytes: Data) throws -> Contract {
        let fields = try ProtoFields(bytes, allowed: [1: .varint, 2: .bytes, 5: .varint])

        guard try fields.optionalInt64(5) ?? 0 == 0 else {
            throw invalid("only the owner permission is supported")
        }

        let type = try fields.requiredInt64(1)
        let any = try ProtoFields(try fields.requiredBytes(2), allowed: [1: .bytes, 2: .bytes])
        let typeURL = String(data: try any.requiredBytes(1), encoding: .utf8)
        let value = any.optionalBytes(2) ?? Data()

        switch (type, typeURL) {
        case (1, transferTypeURL):
            return try decodeTransfer(value)
        case (31, triggerTypeURL):
            return try decodeTrigger(value)
        default:
            throw invalid("unsupported contract type \(type)")
        }
    }

    static func decodeTransfer(_ bytes: Data) throws -> Contract {
        let fields = try ProtoFields(bytes, allowed: [1: .bytes, 2: .bytes, 3: .varint])
        return .transfer(
            owner: try address(fields.requiredBytes(1)),
            to: try address(fields.requiredBytes(2)),
            amount: try fields.optionalInt64(3) ?? 0
        )
    }

    static func decodeTrigger(_ bytes: Data) throws -> Contract {
        let fields = try ProtoFields(
            bytes,
            allowed: [1: .bytes, 2: .bytes, 3: .varint, 4: .bytes, 5: .varint, 6: .varint]
        )

        guard try fields.optionalInt64(5) ?? 0 == 0, try fields.optionalInt64(6) ?? 0 == 0 else {
            throw invalid("TRC-10 call values are not supported")
        }

        return .triggerSmartContract(
            owner: try address(fields.requiredBytes(1)),
            contract: try address(fields.requiredBytes(2)),
            callValue: try fields.optionalInt64(3) ?? 0,
            data: fields.optionalBytes(4) ?? Data()
        )
    }

    static func address(_ bytes: Data) throws -> TronAddress {
        do {
            return try TronAddress(rawBytes: bytes)
        } catch {
            throw invalid("invalid address")
        }
    }

    static func invalid(_ reason: String) -> BlockchainClientError {
        .decodingFailed(reason: "Tron transaction: \(reason)")
    }
}

// MARK: - Protobuf reader

/// One message's fields, read strictly: every field must be in `allowed`
/// with its declared wire type and appear at most once.
private struct ProtoFields {
    enum WireType: UInt64 {
        case varint = 0
        case bytes = 2
    }

    private var bytes: [UInt64: Data] = [:]
    private var varints: [UInt64: UInt64] = [:]

    init(_ data: Data, allowed: [UInt64: WireType]) throws {
        var reader = ProtoReader(data: data)

        while !reader.isAtEnd {
            let key = try reader.varint()
            let number = key >> 3

            guard
                let wireType = WireType(rawValue: key & 0x7),
                allowed[number] == wireType,
                bytes[number] == nil,
                varints[number] == nil
            else {
                throw TronRawTransaction.invalidField(number)
            }

            switch wireType {
            case .varint:
                varints[number] = try reader.varint()
            case .bytes:
                bytes[number] = try reader.lengthDelimited()
            }
        }
    }

    func optionalBytes(_ number: UInt64) -> Data? {
        bytes[number]
    }

    func requiredBytes(_ number: UInt64) throws -> Data {
        guard let value = bytes[number] else {
            throw TronRawTransaction.invalidField(number)
        }

        return value
    }

    /// A non-negative protobuf `int64`.
    func optionalInt64(_ number: UInt64) throws -> UInt64? {
        guard let value = varints[number] else {
            return nil
        }

        guard value <= UInt64(Int64.max) else {
            throw TronRawTransaction.invalidField(number)
        }

        return value
    }

    func requiredInt64(_ number: UInt64) throws -> UInt64 {
        guard let value = try optionalInt64(number) else {
            throw TronRawTransaction.invalidField(number)
        }

        return value
    }
}

private struct ProtoReader {
    let data: Data
    private var offset: Data.Index

    init(data: Data) {
        self.data = data
        offset = data.startIndex
    }

    var isAtEnd: Bool {
        offset == data.endIndex
    }

    mutating func varint() throws -> UInt64 {
        var value: UInt64 = 0

        for shift in stride(from: UInt64(0), to: 70, by: 7) {
            guard offset < data.endIndex else {
                throw TronRawTransaction.truncated
            }

            let byte = data[offset]
            offset += 1

            guard shift < 63 || byte <= 1 else {
                throw TronRawTransaction.truncated
            }

            value |= UInt64(byte & 0x7f) << shift

            if byte & 0x80 == 0 {
                return value
            }
        }

        throw TronRawTransaction.truncated
    }

    mutating func lengthDelimited() throws -> Data {
        let length = try varint()

        guard length <= UInt64(data.endIndex - offset) else {
            throw TronRawTransaction.truncated
        }

        let end = offset + Int(length)
        defer { offset = end }

        return Data(data[offset..<end])
    }
}

private extension TronRawTransaction {
    static var truncated: BlockchainClientError {
        invalid("malformed protobuf")
    }

    static func invalidField(_ number: UInt64) -> BlockchainClientError {
        invalid("unexpected, repeated or missing field \(number)")
    }
}

extension Data {
    /// Lowercase hex without a `0x` prefix, as TronGrid uses.
    var bareHex: String {
        map { String(format: "%02x", $0) }.joined()
    }
}
