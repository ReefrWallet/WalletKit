//
//  Base58.swift
//  WalletKit
//
//  Created by Andrey Yurkevich on 28/08/2026.
//  Copyright © 2026 Reefr Wallet. All rights reserved.
//

import Foundation

/// Decodes/encodes Base58 (Bitcoin-alphabet) strings — the encoding Sui's
/// gRPC API uses for object and transaction digests, and Solana uses for
/// addresses, blockhashes, and transaction signatures, as opposed to the
/// `0x`-hex encoding used elsewhere.
///
/// Public so app-level code can decode a ``SolanaRPCClient/sendTransaction(_:options:)``
/// response's Base58 transaction signature into raw bytes; internally also
/// consumed by ``SuiGRPCClient/ownedCoins(of:coinType:)`` when decoding the
/// `digest` field of each returned object reference.
public enum Base58 {
    private static let alphabet = Array("123456789ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz")
    private static let indexByCharacter = Dictionary(
        uniqueKeysWithValues: alphabet.enumerated().map { ($1, $0) }
    )

    /// Decodes `string` from Base58 to its raw bytes.
    ///
    /// - Parameter string: A Base58-encoded string, e.g. a Sui object digest
    ///   as returned by `ListOwnedObjects`, or a Solana transaction signature.
    /// - Throws: ``BlockchainClientError/decodingFailed(reason:)`` if
    ///   `string` contains any character outside the Base58 alphabet.
    public static func decode(_ string: String) throws -> Data {
        var bytes: [Int] = [0]
        for character in string {
            guard let digit = indexByCharacter[character] else {
                throw BlockchainClientError.decodingFailed(
                    reason: "'\(string)' is not valid Base58 (bad character '\(character)')"
                )
            }

            var carry = digit
            for index in 0..<bytes.count {
                let value = bytes[index] * 58 + carry
                bytes[index] = value & 0xFF
                carry = value >> 8
            }

            while carry > 0 {
                bytes.append(carry & 0xFF)
                carry >>= 8
            }
        }

        let leadingZeros = string.prefix(while: { $0 == "1" }).count
        let significant = Data(bytes.reversed().map { UInt8($0) })
        return Data(repeating: 0, count: leadingZeros) + significant
    }

    public static func encode(_ data: Data) -> String {
        guard !data.isEmpty else {
            return ""
        }

        var digits: [Int] = [0]
        for byte in data {
            var carry = Int(byte)
            for index in 0..<digits.count {
                let value = digits[index] * 256 + carry
                digits[index] = value % 58
                carry = value / 58
            }

            while carry > 0 {
                digits.append(carry % 58)
                carry /= 58
            }
        }

        let leadingZeros = data.prefix(while: { $0 == 0 }).count
        let encoded = digits.reversed().map { alphabet[$0] }

        return String(repeating: "1", count: leadingZeros) + String(encoded)
    }
}
