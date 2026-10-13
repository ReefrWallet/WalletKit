//
//  MoveType.swift
//  WalletKit
//
//  Copyright © 2026 Reefr Wallet. All rights reserved.
//

import Foundation

/// A parsed Move `TypeTag`, encodable as BCS (e.g. an Aptos entry function's
/// type argument).
public indirect enum MoveType: Equatable, Sendable {
    case address
    case bool
    case signer
    case structTag(address: Data, module: String, name: String, typeArguments: [MoveType])
    case u128
    case u16
    case u256
    case u32
    case u64
    case u8
    case vector(MoveType)

    private static let maxDepth = 16

    /// Parses `string`, e.g. `"0x1::coin::CoinStore<0x1::aptos_coin::AptosCoin>"`.
    ///
    /// - Throws: ``BlockchainClientError/decodingFailed(reason:)`` for
    ///   malformed input or nesting deeper than 16 levels.
    public init(parsing string: String) throws {
        var parser = Parser(text: Array(string.filter { !$0.isWhitespace }))
        self = try parser.parseType(depth: 0)

        guard parser.isAtEnd else {
            throw BlockchainClientError.decodingFailed(reason: "trailing characters in Move type: \(string)")
        }
    }

    /// BCS `TypeTag` encoding.
    public var bcs: Data {
        switch self {
        case .bool: Data([0])
        case .u8: Data([1])
        case .u64: Data([2])
        case .u128: Data([3])
        case .address: Data([4])
        case .signer: Data([5])
        case let .vector(element): Data([6]) + element.bcs
        case let .structTag(address, module, name, typeArguments):
            Data([7]) + address + BCS.string(module) + BCS.string(name)
                + BCS.uleb128(typeArguments.count) + typeArguments.reduce(Data()) { $0 + $1.bcs }
        case .u16: Data([8])
        case .u32: Data([9])
        case .u256: Data([10])
        }
    }
}

private extension MoveType {
    struct Parser {
        let text: [Character]
        var position = 0

        var isAtEnd: Bool { position == text.count }

        mutating func parseType(depth: Int) throws -> MoveType {
            guard depth < MoveType.maxDepth else {
                throw fail("Move type nested too deeply")
            }

            let token = readWhile { $0.isLetter || $0.isNumber || $0 == "_" }

            switch token {
            case "address": return .address
            case "bool": return .bool
            case "signer": return .signer
            case "u128": return .u128
            case "u16": return .u16
            case "u256": return .u256
            case "u32": return .u32
            case "u64": return .u64
            case "u8": return .u8
            case "vector":
                try expect("<")
                let element = try parseType(depth: depth + 1)
                try expect(">")
                return .vector(element)
            default:
                return try parseStruct(addressToken: token, depth: depth)
            }
        }

        mutating func parseStruct(addressToken: String, depth: Int) throws -> MoveType {
            let address = try Self.address(addressToken)
            try expect("::")
            let module = try identifier()
            try expect("::")
            let name = try identifier()
            var typeArguments: [MoveType] = []

            if peek("<") {
                try expect("<")
                repeat {
                    typeArguments.append(try parseType(depth: depth + 1))
                } while consume(",")
                try expect(">")
            }

            return .structTag(address: address, module: module, name: name, typeArguments: typeArguments)
        }

        /// `0x`-prefixed hex, left-padded to 32 bytes (`0x1` is valid here).
        static func address(_ token: String) throws -> Data {
            guard token.hasPrefix("0x") else {
                throw BlockchainClientError.decodingFailed(reason: "expected a Move type, got \(token)")
            }

            let hex = token.dropFirst(2)

            guard !hex.isEmpty, hex.count <= 64 else {
                throw BlockchainClientError.decodingFailed(reason: "invalid Move address: \(token)")
            }

            let padded = String(repeating: "0", count: 64 - hex.count) + hex

            guard let data = try? Data(hexString: padded) else {
                throw BlockchainClientError.decodingFailed(reason: "invalid Move address: \(token)")
            }

            return data
        }

        mutating func identifier() throws -> String {
            let token = readWhile { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "_") }

            guard let first = token.first, first.isLetter || first == "_" else {
                throw fail("invalid Move identifier")
            }

            return token
        }

        mutating func readWhile(_ predicate: (Character) -> Bool) -> String {
            let start = position
            while position < text.count, predicate(text[position]) {
                position += 1
            }

            return String(text[start..<position])
        }

        func peek(_ literal: String) -> Bool {
            let characters = Array(literal)
            guard position + characters.count <= text.count else {
                return false
            }

            return Array(text[position..<position + characters.count]) == characters
        }

        mutating func consume(_ literal: String) -> Bool {
            guard peek(literal) else {
                return false
            }

            position += literal.count
            return true
        }

        mutating func expect(_ literal: String) throws {
            guard consume(literal) else {
                throw fail("expected \(literal)")
            }
        }

        func fail(_ reason: String) -> BlockchainClientError {
            .decodingFailed(reason: "\(reason) at offset \(position) in \(String(text))")
        }
    }
}
