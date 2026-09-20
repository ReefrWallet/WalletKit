//
//  Networks.swift
//  WalletKit
//
//  Created by Andrey Yurkevich on 25/08/2026.
//  Copyright © 2026 Reefr Wallet. All rights reserved.
//

import Foundation

public enum BitcoinNetwork: Codable, Equatable, Hashable, Sendable {
    case mainnet
    case testnet

    public static var allNetworks: [WKBlockchain] {
        [.bitcoin(.mainnet), .bitcoin(.testnet)]
    }

    public var name: String {
        switch self {
        case .mainnet: "Mainnet"
        case .testnet: "Testnet"
        }
    }

    public var rpcURL: URL {
        URL(string: "https://localhost")! // TODO
    }
}

public enum CardanoNetwork: Codable, Equatable, Hashable, Sendable {
    case mainnet
    case testnet(UInt64)

    public static var allNetworks: [WKBlockchain] {
        [.cardano(.mainnet), .cardano(.testnet(0))]
    }

    public var name: String {
        switch self {
        case .mainnet: "Mainnet"
        case let .testnet(magic):
            switch magic {
            case 1: "Preprod"
            case 2: "Preview"
            default: "Testnet (magic: \(magic))"
            }
        }
    }

    public var rpcURL: URL {
        URL(string: "https://localhost")! // TODO
    }
}

public enum SolanaNetwork: Codable, Equatable, Hashable, Sendable {
    case mainnet
    case testnet
    case devnet

    public static var allNetworks: [WKBlockchain] {
        [.solana(.mainnet), .solana(.testnet), .solana(.devnet)]
    }

    public var name: String {
        switch self {
        case .mainnet: "Mainnet"
        case .testnet: "Testnet"
        case .devnet: "Devnet"
        }
    }

    public var rpcURL: URL {
        URL(string: "https://localhost")! // TODO
    }
}

public enum TronNetwork: Codable, Equatable, Hashable, Sendable {
    case mainnet
    case testnet

    public static var allNetworks: [WKBlockchain] {
        [.tron(.mainnet), .tron(.testnet)]
    }

    public var name: String {
        switch self {
        case .mainnet: "Mainnet"
        case .testnet: "Nile"
        }
    }

    public var rpcURL: URL {
        URL(string: "https://localhost")! // TODO
    }
}
