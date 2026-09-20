//
//  EthereumRPCParams.swift
//  WalletKit
//
//  Created by Andrey Yurkevich on 28/08/2026.
//  Copyright © 2026 Reefr Wallet. All rights reserved.
//

/// `eth_call`'s heterogeneous `[{to, data}, "latest"]` params — encoded
/// manually since the two elements aren't the same type.
struct EthCallParams: Encodable {
    let to: String
    let data: String

    private struct CallObject: Encodable {
        let to: String
        let data: String
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.unkeyedContainer()
        try container.encode(CallObject(to: to, data: data))
        try container.encode("latest")
    }
}

/// `eth_getBlockByNumber`'s `["latest", false]` params — heterogeneous,
/// so encoded manually. `false` skips full transaction objects, returning
/// only the block header (which includes `baseFeePerGas`).
struct LatestBlockParams: Encodable {
    func encode(to encoder: Encoder) throws {
        var container = encoder.unkeyedContainer()
        try container.encode("latest")
        try container.encode(false)
    }
}

/// The subset of a block header returned by `eth_getBlockByNumber` that
/// `estimateFee` reads — just `baseFeePerGas` (EIP-1559). Other fields
/// are present in the node's response but intentionally not decoded.
struct LatestBlock: Decodable {
    /// The block's base fee per gas in "Quantity" hex, e.g. `"0x5f5e100"`.
    /// `nil` on pre-EIP-1559 blocks (not seen in practice on mainnet/
    /// testnets, but guarded against defensively; treated as 0).
    let baseFeePerGas: String?
}

/// `eth_estimateGas`'s `[{from?, to, value?, data?}]` params — a single-
/// element array containing a call object. `nil` fields are omitted from the
/// encoded output so the node uses its own defaults (e.g. zero address for
/// `from`, zero value for `value`).
struct EstimateGasParams: Encodable {
    let from: String?
    let to: String
    let value: String?
    let data: String?

    private struct CallObject: Encodable {
        let from: String?
        let to: String
        let value: String?
        let data: String?

        enum CodingKeys: String, CodingKey { case from, to, value, data }

        func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            if let from { try container.encode(from, forKey: .from) }
            try container.encode(to, forKey: .to)
            if let value { try container.encode(value, forKey: .value) }
            if let data { try container.encode(data, forKey: .data) }
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.unkeyedContainer()
        try container.encode(CallObject(from: from, to: to, value: value, data: data))
    }
}
