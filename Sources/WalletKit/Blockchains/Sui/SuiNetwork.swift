//
//  SuiNetwork.swift
//  WalletKit
//
//  Created by Andrey Yurkevich on 25/08/2026.
//  Copyright © 2026 Reefr Wallet. All rights reserved.
//

import Foundation

public enum SuiNetwork: Equatable, Hashable, Codable, Sendable {
    case mainnet
    case testnet

    public static var allNetworks: [WKBlockchain] {
        [.sui(.mainnet), .sui(.testnet)]
    }

    public var name: String {
        switch self {
        case .mainnet: "Mainnet"
        case .testnet: "Testnet"
        }
    }

    public var rpcURL: URL {
        switch self {
        case .mainnet: URL(string: "https://fullnode.mainnet.sui.io:443")!
        case .testnet: URL(string: "https://fullnode.testnet.sui.io:443")!
        }
    }
}
