//
//  SuiGRPCClient+BlockchainClientProtocol.swift
//  WalletKit
//
//  Created by Andrey Yurkevich on 20/08/2026.
//  Copyright © 2026 Reefr Wallet. All rights reserved.
//

/// ``BlockchainClientProtocol`` conformance for ``SuiGRPCClient``.
extension SuiGRPCClient: BlockchainClientProtocol {
    public func getAllBalances(_ owner: SuiAddress) async throws -> [String: BigUInt] {
        let response = try await listAllBalances(of: owner)
        return response.reduce(into: [String: BigUInt]()) { result, balance in
            result[balance.coinType] = BigUInt(balance.balance)
        }
    }

    public func getBalances(_ owner: SuiAddress, tokens: [String]) async throws -> [String: BigUInt] {
        let response = try await listAllBalances(of: owner)
        var balances: [String: BigUInt] = [:]
        for balance in response {
            if tokens.isEmpty || tokens.contains(balance.coinType) {
                balances[balance.coinType] = BigUInt(balance.balance)
            }
        }

        return balances
    }

    public func getBalance(_ owner: SuiAddress, token: String) async throws -> BigUInt {
        BigUInt(try await coinBalance(of: owner, coinType: token))
    }

    public func getNativeBalance(_ owner: SuiAddress) async throws -> BigUInt {
        BigUInt(try await nativeBalance(of: owner))
    }

    public func getTokenInfo(_ token: String?) async throws -> TokenInfo {
        guard let token else {
            return .sui
        }

        return try await coinInfo(coinType: token)
    }

    public func isActiveAccount(_ owner: SuiAddress) async throws -> Bool {
        let ownedObjects = try await getOwnedObjects(owner)
        return ownedObjects.isEmpty == false
    }

    public func isSupported(_ feature: BlockchainClientFeature) -> Bool {
        switch feature {
        case .multipleBalances: true
        case .allBalances: true
        case .transactionHistory: true
        case .transactionSubscription: true
        }
    }

    /// Broadcasts a signed Sui transaction.
    ///
    /// `transaction` is the unsigned BCS-encoded `TransactionData` and
    /// `signature` is the serialized Sui signature returned by
    /// ``SuiPKeySigner/sign(transaction:)``.
    public func broadcast(transaction: Data, signature: Data) async throws -> String {
        try await broadcast(transactionData: transaction, signature: signature)
    }
}
