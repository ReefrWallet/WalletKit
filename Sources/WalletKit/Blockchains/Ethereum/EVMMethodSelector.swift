//
//  EVMMethodSelector.swift
//  WalletKit
//

import Foundation

/// Display names for common 4-byte selectors; node-only history has no ABI to decode the rest.
enum EVMMethodSelector {
    static let names: [String: String] = [
        "095ea7b3": "Approve",
        "18cbafe5": "Swap Exact Tokens For ETH",
        "23b872dd": "Transfer From",
        "2e1a7d4d": "Withdraw",
        "3593564c": "Execute",
        "38ed1739": "Swap Exact Tokens For Tokens",
        "5ae401dc": "Multicall",
        "7ff36ab5": "Swap Exact ETH For Tokens",
        "a9059cbb": "Transfer",
        "ac9650d8": "Multicall",
        "d0e30db0": "Deposit"
    ]

    static func name(input: String?) -> String {
        let data = input.map { $0.hasPrefix("0x") ? String($0.dropFirst(2)) : $0 } ?? ""

        guard data.count >= 8 else {
            return "Transfer"
        }

        return names[String(data.prefix(8)).lowercased()] ?? "Contract Call"
    }
}
