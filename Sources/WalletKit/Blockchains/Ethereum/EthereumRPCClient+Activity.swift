//
//  EthereumRPCClient+Activity.swift
//  WalletKit
//
//  Created by Andrey Yurkevich on 26/11/2026.
//  Copyright © 2026 Reefr Wallet. All rights reserved.
//

extension EthereumRPCClient {
    /// Whether each of `addresses` has sent a transaction or holds a native
    /// balance, in order.
    ///
    /// Nonces, then balances of the addresses without one, are read in one
    /// JSON-RPC batch each. An endpoint that rejects batches, or a batch
    /// entry that fails, falls back to ``isActiveAccount(_:)`` per address.
    /// Token-only addresses aren't detected: that needs an indexer.
    ///
    /// - Throws: ``BlockchainClientError`` on a transport, RPC, quota, or
    ///   decoding failure.
    public func activity(of addresses: [EthereumAddress]) async throws -> [Bool] {
        guard !addresses.isEmpty else {
            return []
        }

        let nonces: [String?]

        do {
            nonces = try await rpc.callBatch(
                method: "eth_getTransactionCount",
                params: addresses.map { [$0.string, "latest"] }
            )
        } catch let error as BlockchainClientError where error.isBatchRejection {
            return try await sequentialActivity(of: addresses)
        }

        var result: [Bool?] = try nonces.map { hex in
            try hex.map { try parseQuantity($0) > 0 }
        }

        let pending = result.indices.filter { result[$0] != true }
        let balances: [String?]

        do {
            balances = try await rpc.callBatch(
                method: "eth_getBalance",
                params: pending.map { [addresses[$0].string, "latest"] }
            )
        } catch let error as BlockchainClientError where error.isBatchRejection {
            balances = Array(repeating: nil, count: pending.count)
        }

        for (index, hex) in zip(pending, balances) {
            if let hex, try parseQuantity(hex) > 0 {
                result[index] = true
            } else if hex == nil || result[index] == nil {
                result[index] = try await isActiveAccount(addresses[index])
            }
        }

        return result.map { $0 ?? false }
    }

    private func sequentialActivity(of addresses: [EthereumAddress]) async throws -> [Bool] {
        var result: [Bool] = []

        for address in addresses {
            result.append(try await isActiveAccount(address))
        }

        return result
    }
}

private extension BlockchainClientError {
    /// An answer that isn't a batch reply: the endpoint doesn't take batches.
    var isBatchRejection: Bool {
        switch self {
        case .decodingFailed, .invalidResponse, .rpcError: true
        case .quotaExceeded, .serverError, .transportError: false
        }
    }
}
