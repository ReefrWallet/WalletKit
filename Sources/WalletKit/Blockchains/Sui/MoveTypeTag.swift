//
//  MoveTypeTag.swift
//  WalletKit
//
//  Created by Andrey Yurkevich on 22/08/2026.
//  Copyright © 2026 Reefr Wallet. All rights reserved.
//

/// Move type-tag string helpers — parsing a Move struct tag's generic
/// type arguments and normalizing a coin type's address so two
/// differently-formatted references to the same coin compare equal.
public enum MoveTypeTag {
    /// Splits a Move struct tag's generic type arguments — e.g.
    /// `"<pkg>::pool::Pool<0x2::sui::SUI, <pkg>::usdc::USDC>"` splits to
    /// `["0x2::sui::SUI", "<pkg>::usdc::USDC"]` — respecting nested
    /// `<...>` so a generic coin type's own type arguments don't get
    /// split on their commas.
    ///
    /// - Parameter typeTag: The Move struct tag to split.
    /// - Throws: ``BlockchainClientError/decodingFailed(reason:)`` if
    ///   `typeTag` has no generic type arguments (no `<...>` suffix).
    public static func genericTypeArguments(of typeTag: String) throws -> [String] {
        guard let openIndex = typeTag.firstIndex(of: "<"), typeTag.hasSuffix(">") else {
            throw BlockchainClientError.decodingFailed(reason: "type tag has no generic type arguments: \(typeTag)")
        }

        let inner = typeTag[typeTag.index(after: openIndex)..<typeTag.index(before: typeTag.endIndex)]

        var arguments: [String] = []
        var depth = 0
        var current = ""
        for character in inner {
            switch character {
            case "<":
                depth += 1
                current.append(character)
            case ">":
                depth -= 1
                current.append(character)
            case "," where depth == 0:
                arguments.append(current.trimmingCharacters(in: .whitespaces))
                current = ""
            default:
                current.append(character)
            }
        }

        arguments.append(current.trimmingCharacters(in: .whitespaces))

        return arguments
    }

    /// Normalizes a Move coin type's leading package address to Sui's
    /// canonical 64-hex-digit, lowercase, `0x`-prefixed form, e.g.
    /// `"0x2::sui::SUI"` and `"0x0000...0002::sui::SUI"` (the form a
    /// node's `object_type` returns addresses in) both normalize to the
    /// same string — needed because Sui accepts either form as input but
    /// only ever returns the long form, so comparing a caller-supplied
    /// coin type against one read back from chain state needs both sides
    /// normalized first.
    ///
    /// - Parameter coinType: The coin type to normalize, e.g.
    ///   `"0x2::sui::SUI"`.
    /// - Throws: ``BlockchainClientError/decodingFailed(reason:)`` if
    ///   `coinType` has no `::`-separated address prefix.
    public static func canonicalCoinType(_ coinType: String) throws -> String {
        guard let separatorRange = coinType.range(of: "::") else {
            throw BlockchainClientError.decodingFailed(reason: "not a valid coin type: \(coinType)")
        }

        let addressPart = coinType[coinType.startIndex..<separatorRange.lowerBound]
        let rest = coinType[separatorRange.lowerBound...]

        let hex = addressPart.hasPrefix("0x") ? addressPart.dropFirst(2) : addressPart[...]
        guard hex.count <= 64 else {
            throw BlockchainClientError.decodingFailed(reason: "coin type address is too long: \(coinType)")
        }

        let padded = String(repeating: "0", count: 64 - hex.count) + hex
        return "0x" + padded.lowercased() + rest
    }
}
