//
//  HexCoding.swift
//  WalletKit
//
//  Created by Andrey Yurkevich on 17/08/2026.
//  Copyright © 2026 Reefr Wallet. All rights reserved.
//

import Foundation

/// `0x`-prefixed hex encoding/decoding, as used throughout Ethereum's
/// JSON-RPC (addresses, calldata, balances, raw transactions).
extension Data {
    /// Decodes a `0x`-prefixed (or bare) hex string.
    ///
    /// - Parameter hexString: The hex string to decode.
    /// - Throws: `BlockchainClientError.decodingFailed(reason:)` if
    ///   `hexString` has an odd number of hex digits or contains
    ///   non-hex characters.
    init(hexString: String) throws {
        let hex = hexString.hasPrefix("0x") ? String(hexString.dropFirst(2)) : hexString
        guard hex.count.isMultiple(of: 2) else {
            throw BlockchainClientError.decodingFailed(reason: "odd number of hex digits: \(hexString)")
        }

        var data = Data(capacity: hex.count / 2)
        var index = hex.startIndex
        while index < hex.endIndex {
            let next = hex.index(index, offsetBy: 2)
            guard let byte = UInt8(hex[index..<next], radix: 16) else {
                throw BlockchainClientError.decodingFailed(reason: "invalid hex digits in: \(hexString)")
            }

            data.append(byte)
            index = next
        }

        self = data
    }

    /// The `0x`-prefixed, lowercase hex encoding of this data.
    var hexEncoded: String {
        "0x" + map { String(format: "%02x", $0) }.joined()
    }
}
