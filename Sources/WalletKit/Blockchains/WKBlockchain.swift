//
//  SuiNetwork.swift
//  WalletKit
//
//  Created by Andrey Yurkevich on 24/08/2026.
//  Copyright © 2026 Reefr Wallet. All rights reserved.
//

import SwiftUI
import WalletKitRust

// MARK: - WKBlockchain

/// A chain identifier — one case per supported blockchain.
public enum WKBlockchain: Equatable, Hashable, Codable, Sendable {
    case bitcoin(BitcoinNetwork)
    case evm(EVMBlockchain)
    case tron(TronNetwork)
    case solana(SolanaNetwork)
    case cardano(CardanoNetwork)
    case sui(SuiNetwork)

    init(raw: BlockchainFfi) {
        switch raw {
        case .bitcoin: self = .bitcoin(.mainnet)
        case let .ethereum(chainId): self = .evm(EVMBlockchain(chainId: chainId))
        case .tron: self = .tron(.mainnet)
        case .solana: self = .solana(.mainnet)
        case .cardano: self = .cardano(.mainnet)
        case .sui: self = .sui(.mainnet)
        }
    }
}

public extension WKBlockchain {
    static var allMainnets: [WKBlockchain] {
        let mainnets = [WKBlockchain.sui(.mainnet)] + EVMBlockchain.allMainnets // others are not yet supported
        return mainnets.sorted { $0 < $1 }
    }

    var allNetworks: [WKBlockchain] {
        switch self {
        case .bitcoin:
            BitcoinNetwork.allNetworks
        case let .evm(chain):
            chain.allNetworks
        case .tron:
            TronNetwork.allNetworks
        case .solana:
            SolanaNetwork.allNetworks
        case .cardano:
            CardanoNetwork.allNetworks
        case .sui:
            SuiNetwork.allNetworks
        }
    }

    /// E. g. "Ethereum Mainnet" or "Ethereum Sepolia"
    var displayName: String {
        [name, networkName].joined(separator: " ")
    }

    var isCustomEVM: Bool {
        if case let .evm(chain) = self, case .custom = chain {
            true
        } else {
            false
        }
    }

    var isMainnet: Bool {
        switch self {
        case let .bitcoin(network):
            network == .mainnet
        case let .evm(chain):
            chain.isMainnet
        case let .tron(network):
            network == .mainnet
        case let .solana(network):
            network == .mainnet
        case let .cardano(network):
            network == .mainnet
        case let .sui(network):
            network == .mainnet
        }
    }

    var logoImage: Image {
        switch self {
        case .bitcoin:
            Image("btc-logo")
        case let .evm(chain):
            chain.logoImage
        case .tron:
            Image("trx-logo")
        case .solana:
            Image("sol-logo")
        case .cardano:
            Image("ada-logo")
        case .sui:
            Image("sui-logo")
        }
    }

    var name: String {
        switch self {
        case .bitcoin: "Bitcoin"
        case let .evm(chain): chain.name
        case .tron: "Tron"
        case .solana: "Solana"
        case .cardano: "Cardano"
        case .sui: "Sui"
        }
    }

    /// E. g. "Mainnet" or "Sepolia"
    var networkName: String {
        switch self {
        case let .bitcoin(network): network.name
        case let .evm(blockchain): blockchain.networkName
        case let .tron(network): network.name
        case let .solana(network): network.name
        case let .cardano(network): network.name
        case let .sui(network): network.name
        }
    }

    var nativeToken: TokenInfo {
        switch self {
        case .bitcoin: .bitcoin
        case .cardano: .ada
        case let .evm(chain): chain.nativeToken
        case .solana: .solana
        case .sui: .sui
        case .tron: .tron
        }
    }

    var raw: BlockchainFfi {
        switch self {
        case .bitcoin: .bitcoin
        case let .evm(chain): .ethereum(chain.chainId)
        case .tron: .tron
        case .solana: .solana
        case .cardano: .cardano
        case .sui: .sui
        }
    }

    var rpcURL: URL {
        switch self {
        case let .bitcoin(network):
            network.rpcURL
        case let .evm(chain):
            chain.rpcURL
        case let .tron(network):
            network.rpcURL
        case let .solana(network):
            network.rpcURL
        case let .cardano(network):
            network.rpcURL
        case let .sui(network):
            network.rpcURL
        }
    }
}

extension WKBlockchain: Comparable {
    public static func < (lhs: WKBlockchain, rhs: WKBlockchain) -> Bool {
        lhs.displayName < rhs.displayName
    }
}
