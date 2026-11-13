//
//  TonNetwork.swift
//  WalletKit
//
//  Copyright © 2026 Reefr Wallet. All rights reserved.
//

import Foundation

public enum TonNetwork: Equatable, Hashable, Codable, Sendable {
    case mainnet
    case testnet

    public static var allNetworks: [Blockchain] {
        [.ton(.mainnet), .ton(.testnet)]
    }

    /// The network's global id, which V5R1 mixes into the wallet id so that
    /// a signed message is valid on one network only.
    public var globalId: Int32 {
        switch self {
        case .mainnet: -239
        case .testnet: -3
        }
    }

    public var name: String {
        switch self {
        case .mainnet: "Mainnet"
        case .testnet: "Testnet"
        }
    }

    /// The toncenter API v2 endpoint.
    public var rpcURL: URL {
        switch self {
        case .mainnet: URL(string: "https://toncenter.com/api/v2")!
        case .testnet: URL(string: "https://testnet.toncenter.com/api/v2")!
        }
    }

    /// The toncenter API v3 (indexer) endpoint.
    public var indexerURL: URL {
        switch self {
        case .mainnet: URL(string: "https://toncenter.com/api/v3")!
        case .testnet: URL(string: "https://testnet.toncenter.com/api/v3")!
        }
    }
}
