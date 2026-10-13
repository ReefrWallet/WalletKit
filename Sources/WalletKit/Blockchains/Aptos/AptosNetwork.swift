//
//  AptosNetwork.swift
//  WalletKit
//
//  Copyright © 2026 Reefr Wallet. All rights reserved.
//

import Foundation

public enum AptosNetwork: Equatable, Hashable, Codable, Sendable {
    case mainnet
    case testnet

    public static var allNetworks: [Blockchain] {
        [.aptos(.mainnet), .aptos(.testnet)]
    }

    public var name: String {
        switch self {
        case .mainnet: "Mainnet"
        case .testnet: "Testnet"
        }
    }

    /// The Aptos Labs full-node REST endpoint.
    public var rpcURL: URL {
        switch self {
        case .mainnet: URL(string: "https://api.mainnet.aptoslabs.com/v1")!
        case .testnet: URL(string: "https://api.testnet.aptoslabs.com/v1")!
        }
    }

    /// The Aptos Labs indexer GraphQL endpoint.
    public var indexerURL: URL {
        rpcURL.appending(path: "graphql")
    }
}
