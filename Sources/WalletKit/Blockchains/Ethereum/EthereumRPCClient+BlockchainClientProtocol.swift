//
//  EthereumRPCClient+BlockchainClientProtocol.swift
//  WalletKit
//
//  Created by Andrey Yurkevich on 20/08/2026.
//  Copyright © 2026 Reefr Wallet. All rights reserved.
//

import BigInt

/// ``BlockchainClientProtocol`` conformance for ``EthereumRPCClient``.
extension EthereumRPCClient: BlockchainClientProtocol {
    public func getAllBalances(_ owner: EthereumAddress) async throws -> [String: BigUInt] {
        throw WalletKitError.unsupportedFeature
    }

    public func getBalances(_ owner: EthereumAddress, tokens: [String]) async throws -> [String: BigUInt] {
        let addresses = try tokens.map { try EthereumAddress(string: $0) }

        return try await erc20Balances(tokens: addresses, owner: owner)
    }

    public func getBalance(_ owner: EthereumAddress, token: String) async throws -> BigUInt {
        let token = try EthereumAddress(string: token)
        return try await erc20Balance(token: token, owner: owner)
    }

    public func getNativeBalance(_ owner: EthereumAddress) async throws -> BigUInt {
        try await nativeBalance(of: owner)
    }

    public func getTokenInfo(_ token: String?) async throws -> TokenInfo {
        guard let token else {
            return EVMBlockchain(chainId: chainId).nativeToken
        }

        let address = try EthereumAddress(string: token)
        return try await erc20TokenInfo(token: address)
    }

    public func isActiveAccount(_ owner: EthereumAddress) async throws -> Bool {
        guard try await nativeBalance(of: owner) == 0 else {
            return true
        }

        return try await nonce(of: owner) > 0
    }

    public func isSupported(_ feature: BlockchainClientFeature) -> Bool {
        switch feature {
        case .multipleBalances: true
        case .allBalances: false
        case .transactionHistory: true
        case .transactionSubscription: true
        }
    }

    /// Broadcasts a signed Ethereum transaction.
    ///
    /// For Ethereum the signed envelope is self-contained — `transaction`
    /// (the unsigned bytes) is unused. Pass the signed bytes as `signature`.
    public func broadcast(transaction: Data, signature: Data) async throws -> String {
        try await broadcast(signature)
    }
}
