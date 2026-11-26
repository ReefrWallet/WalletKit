//
//  SolanaRPCClient+Activity.swift
//  WalletKit
//
//  Created by Andrey Yurkevich on 26/11/2026.
//  Copyright © 2026 Reefr Wallet. All rights reserved.
//

extension SolanaRPCClient {
    /// Whether each of `owners` has ever been used, in order.
    ///
    /// An owner is used when it holds lamports, has any transaction
    /// signature, or owns a token account under either token program.
    /// Lamports are read for all owners in one `getMultipleAccounts`
    /// request; the other checks run only for owners without lamports.
    ///
    /// - Throws: ``BlockchainClientError`` on a transport, RPC, or
    ///   decoding failure.
    public func activity(of owners: [SolanaAddress]) async throws -> [Bool] {
        let accounts = try await multipleAccounts(owners.map(\.string))
        var result: [Bool] = []

        for (owner, account) in zip(owners, accounts) {
            if let account, account.lamports > 0 {
                result.append(true)
            } else {
                result.append(try await hasHistoryOrTokenAccounts(owner))
            }
        }

        return result
    }

    func hasHistoryOrTokenAccounts(_ owner: SolanaAddress) async throws -> Bool {
        guard try await signaturesForAddress(owner, limit: 1, before: nil, until: nil).isEmpty else {
            return true
        }

        guard try await tokenAccounts(of: owner, tokenProgram: SolanaProgram.token).isEmpty else {
            return true
        }

        return try await !tokenAccounts(of: owner, tokenProgram: SolanaProgram.token2022).isEmpty
    }
}
