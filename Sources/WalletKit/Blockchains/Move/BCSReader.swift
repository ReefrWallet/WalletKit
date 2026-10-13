//
//  BCSReader.swift
//  WalletKit
//
//  Copyright © 2026 Reefr Wallet. All rights reserved.
//

import Foundation

/// A strict BCS decoder: canonical ULEB128, bounded lengths, and an explicit
/// end check. Every failure is ``BlockchainClientError/decodingFailed(reason:)``.
struct BCSReader {
    private let data: Data
    private var offset: Int

    init(_ data: Data) {
        self.data = data
        offset = data.startIndex
    }

    var isAtEnd: Bool { offset == data.endIndex }

    mutating func bytes(_ count: Int) throws -> Data {
        guard count >= 0, data.endIndex - offset >= count else {
            throw Self.failure("unexpected end of input")
        }

        defer { offset += count }
        return data[offset..<offset + count]
    }

    mutating func u8() throws -> UInt8 {
        try bytes(1).first!
    }

    mutating func u64() throws -> UInt64 {
        try bytes(8).reversed().reduce(UInt64(0)) { $0 << 8 | UInt64($1) }
    }

    /// A canonical ULEB128 no larger than `UInt32.max`.
    mutating func uleb128() throws -> Int {
        var value: UInt64 = 0
        var shift: UInt64 = 0

        while true {
            let byte = try u8()
            value |= UInt64(byte & 0x7F) << shift

            if byte & 0x80 == 0 {
                guard shift == 0 || byte != 0 else {
                    throw Self.failure("non-canonical ULEB128")
                }

                break
            }

            shift += 7

            guard shift < 35 else {
                throw Self.failure("ULEB128 too long")
            }
        }

        guard value <= UInt64(UInt32.max) else {
            throw Self.failure("ULEB128 out of range")
        }

        return Int(value)
    }

    /// A length-prefixed vector length, rejected above `limit`.
    mutating func length(limit: Int) throws -> Int {
        let count = try uleb128()

        guard count <= limit else {
            throw Self.failure("length \(count) exceeds \(limit)")
        }

        return count
    }

    mutating func byteVector(limit: Int = 1 << 20) throws -> Data {
        try bytes(try length(limit: limit))
    }

    mutating func string(limit: Int = 1 << 16) throws -> String {
        guard let string = String(data: try byteVector(limit: limit), encoding: .utf8) else {
            throw Self.failure("invalid UTF-8")
        }

        return string
    }

    func expectEnd() throws {
        guard isAtEnd else {
            throw Self.failure("\(data.endIndex - offset) trailing bytes")
        }
    }

    static func failure(_ reason: String) -> BlockchainClientError {
        .decodingFailed(reason: "BCS: \(reason)")
    }
}

extension MoveType {
    /// Decodes a BCS `TypeTag`, nesting at most 16 levels.
    init(bcs reader: inout BCSReader, depth: Int = 0) throws {
        guard depth < 16 else {
            throw BCSReader.failure("type tag nested too deeply")
        }

        switch try reader.u8() {
        case 0: self = .bool
        case 1: self = .u8
        case 2: self = .u64
        case 3: self = .u128
        case 4: self = .address
        case 5: self = .signer
        case 6: self = .vector(try MoveType(bcs: &reader, depth: depth + 1))
        case 7:
            let address = try reader.bytes(32)
            let module = try Self.identifier(&reader)
            let name = try Self.identifier(&reader)
            let count = try reader.length(limit: 32)
            let typeArguments = try (0..<count).map { _ in try MoveType(bcs: &reader, depth: depth + 1) }
            self = .structTag(address: Data(address), module: module, name: name, typeArguments: typeArguments)
        case 8: self = .u16
        case 9: self = .u32
        case 10: self = .u256
        case let tag:
            throw BCSReader.failure("unknown type tag \(tag)")
        }
    }

    /// A Move identifier: `[A-Za-z_][A-Za-z0-9_]*`, at most 128 bytes.
    static func identifier(_ reader: inout BCSReader) throws -> String {
        let identifier = try reader.string(limit: 128)
        let isValid = identifier.first.map { $0.isASCII && ($0.isLetter || $0 == "_") } ?? false
            && identifier.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "_") }

        guard isValid else {
            throw BCSReader.failure("invalid Move identifier \(identifier)")
        }

        return identifier
    }

    /// The canonical Move string, e.g. `0x1::coin::CoinStore<0x1::aptos_coin::AptosCoin>`.
    public var description: String {
        switch self {
        case .address: "address"
        case .bool: "bool"
        case .signer: "signer"
        case .u128: "u128"
        case .u16: "u16"
        case .u256: "u256"
        case .u32: "u32"
        case .u64: "u64"
        case .u8: "u8"
        case let .vector(element): "vector<\(element.description)>"
        case let .structTag(address, module, name, typeArguments):
            "\(Self.shortAddress(address))::\(module)::\(name)"
                + (typeArguments.isEmpty ? "" : "<\(typeArguments.map(\.description).joined(separator: ", "))>")
        }
    }

    /// AIP-40: short form only for special addresses (`0x0`–`0xf`).
    private static func shortAddress(_ address: Data) -> String {
        if address.dropLast().allSatisfy({ $0 == 0 }), let last = address.last, last < 0x10 {
            return String(format: "0x%x", last)
        }

        return "0x" + address.map { String(format: "%02x", $0) }.joined()
    }
}
