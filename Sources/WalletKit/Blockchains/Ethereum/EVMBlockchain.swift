//
//  EVMBlockchain.swift
//  WalletKit
//
//  Created by Andrey Yurkevich on 25/08/2026.
//  Copyright © 2026 Reefr Wallet. All rights reserved.
//

import Foundation

public enum EVMBlockchain: Equatable, Hashable, Codable, Sendable {
    case arbitrum(ArbitrumNetwork)
    case avalanche(AvalancheNetwork)
    case base(BaseNetwork)
    case bsc(BinanceNetwork)
    case ethereum(EthereumNetwork)
    case hyperEVM(HyperEVMNetwork)
    case mantle(MantleNetwork)
    case monad(MonadNetwork)
    case optimism(OptimismNetwork)
    case polygon(PolygonNetwork)
    case robinhood(RobinhoodNetwork)
    case unichain(UnichainNetwork)
    case custom(UInt64)

    public init(chainId: UInt64) {
        self = Self.presets.first { $0.chainId == chainId } ?? .custom(chainId)
    }
}

public extension EVMBlockchain {
    enum ArbitrumNetwork: Equatable, Hashable, Codable, Sendable {
        case mainnet
        case sepolia

        var name: String {
            switch self {
            case .mainnet: "Mainnet"
            case .sepolia: "Sepolia"
            }
        }
    }

    enum AvalancheNetwork: Equatable, Hashable, Codable, Sendable {
        case fuji
        case mainnet

        var name: String {
            switch self {
            case .fuji: "Fuji"
            case .mainnet: "Mainnet"
            }
        }
    }

    enum BaseNetwork: Equatable, Hashable, Codable, Sendable {
        case mainnet
        case sepolia

        var name: String {
            switch self {
            case .mainnet: "Mainnet"
            case .sepolia: "Sepolia"
            }
        }
    }

    enum BinanceNetwork: Equatable, Hashable, Codable, Sendable {
        case mainnet
        case testnet

        var name: String {
            switch self {
            case .mainnet: "Mainnet"
            case .testnet: "Testnet"
            }
        }
    }

    enum EthereumNetwork: Equatable, Hashable, Codable, Sendable {
        case mainnet
        case sepolia

        var name: String {
            switch self {
            case .mainnet: "Mainnet"
            case .sepolia: "Sepolia"
            }
        }
    }

    enum HyperEVMNetwork: Equatable, Hashable, Codable, Sendable {
        case mainnet
        case testnet

        var name: String {
            switch self {
            case .mainnet: "Mainnet"
            case .testnet: "Testnet"
            }
        }
    }

    enum MantleNetwork: Equatable, Hashable, Codable, Sendable {
        case mainnet
        case sepolia

        var name: String {
            switch self {
            case .mainnet: "Mainnet"
            case .sepolia: "Sepolia"
            }
        }
    }

    enum MonadNetwork: Equatable, Hashable, Codable, Sendable {
        case mainnet
        case testnet

        var name: String {
            switch self {
            case .mainnet: "Mainnet"
            case .testnet: "Testnet"
            }
        }
    }

    enum OptimismNetwork: Equatable, Hashable, Codable, Sendable {
        case mainnet
        case sepolia

        var name: String {
            switch self {
            case .mainnet: "Mainnet"
            case .sepolia: "Sepolia"
            }
        }
    }

    enum PolygonNetwork: Equatable, Hashable, Codable, Sendable {
        case amoy
        case mainnet

        var name: String {
            switch self {
            case .amoy: "Amoy"
            case .mainnet: "Mainnet"
            }
        }
    }

    enum RobinhoodNetwork: Equatable, Hashable, Codable, Sendable {
        case mainnet
        case testnet

        var name: String {
            switch self {
            case .mainnet: "Mainnet"
            case .testnet: "Testnet"
            }
        }
    }

    enum UnichainNetwork: Equatable, Hashable, Codable, Sendable {
        case mainnet
        case sepolia

        var name: String {
            switch self {
            case .mainnet: "Mainnet"
            case .sepolia: "Sepolia"
            }
        }
    }
}

public extension EVMBlockchain {
    static var allMainnets: [Blockchain] {
        presets.filter(\.isMainnet).map(Blockchain.evm) + [.evm(.custom(1))]
    }

    /// Every built-in network, mainnets and testnets.
    static var presets: [EVMBlockchain] {
        [
            .arbitrum(.mainnet), .arbitrum(.sepolia),
            .avalanche(.mainnet), .avalanche(.fuji),
            .base(.mainnet), .base(.sepolia),
            .bsc(.mainnet), .bsc(.testnet),
            .ethereum(.mainnet), .ethereum(.sepolia),
            .hyperEVM(.mainnet), .hyperEVM(.testnet),
            .mantle(.mainnet), .mantle(.sepolia),
            .monad(.mainnet), .monad(.testnet),
            .optimism(.mainnet), .optimism(.sepolia),
            .polygon(.mainnet), .polygon(.amoy),
            .robinhood(.mainnet), .robinhood(.testnet),
            .unichain(.mainnet), .unichain(.sepolia)
        ]
    }

    var allNetworks: [Blockchain] {
        guard case let .custom(chainId) = self else {
            return Self.presets.filter { $0.isSameBlockchain(as: self) }.map(Blockchain.evm)
        }

        return [.evm(.custom(chainId))]
    }

    var chainId: UInt64 {
        switch self {
        case let .arbitrum(network):
            switch network {
            case .mainnet: 42_161
            case .sepolia: 421_614
            }

        case let .avalanche(network):
            switch network {
            case .fuji: 43_113
            case .mainnet: 43_114
            }

        case let .base(network):
            switch network {
            case .mainnet: 8_453
            case .sepolia: 84_532
            }

        case let .bsc(network):
            switch network {
            case .mainnet: 56
            case .testnet: 97
            }

        case let .ethereum(network):
            switch network {
            case .mainnet: 1
            case .sepolia: 11_155_111
            }

        case let .hyperEVM(network):
            switch network {
            case .mainnet: 999
            case .testnet: 998
            }

        case let .mantle(network):
            switch network {
            case .mainnet: 5_000
            case .sepolia: 5_003
            }

        case let .monad(network):
            switch network {
            case .mainnet: 143
            case .testnet: 10_143
            }

        case let .optimism(network):
            switch network {
            case .mainnet: 10
            case .sepolia: 11_155_420
            }

        case let .polygon(network):
            switch network {
            case .amoy: 80_002
            case .mainnet: 137
            }

        case let .robinhood(network):
            switch network {
            case .mainnet: 4_663
            case .testnet: 46_630
            }

        case let .unichain(network):
            switch network {
            case .mainnet: 130
            case .sepolia: 1_301
            }

        case let .custom(chainId):
            chainId
        }
    }

    var isMainnet: Bool {
        switch self {
        case let .arbitrum(network): network == .mainnet
        case let .avalanche(network): network == .mainnet
        case let .base(network): network == .mainnet
        case let .bsc(network): network == .mainnet
        case let .ethereum(network): network == .mainnet
        case let .hyperEVM(network): network == .mainnet
        case let .mantle(network): network == .mainnet
        case let .monad(network): network == .mainnet
        case let .optimism(network): network == .mainnet
        case let .polygon(network): network == .mainnet
        case let .robinhood(network): network == .mainnet
        case let .unichain(network): network == .mainnet
        case .custom: true
        }
    }

    var name: String {
        switch self {
        case .arbitrum: "Arbitrum"
        case .avalanche: "Avalanche"
        case .base: "Base"
        case .bsc: "BSC"
        case .custom: "Other EVM"
        case .ethereum: "Ethereum"
        case .hyperEVM: "HyperEVM"
        case .mantle: "Mantle"
        case .monad: "Monad"
        case .optimism: "Optimism"
        case .polygon: "Polygon"
        case .robinhood: "Robinhood Chain"
        case .unichain: "Unichain"
        }
    }

    var nativeToken: TokenInfo {
        switch self {
        case .arbitrum: TokenInfo(decimals: 18, name: "Arbitrum Ether", isNative: true, symbol: "ETH")
        case .avalanche: TokenInfo(decimals: 18, name: "Avalanche", isNative: true, symbol: "AVAX")
        case .base, .ethereum, .optimism, .robinhood, .unichain:
            TokenInfo(decimals: 18, name: "Ether", isNative: true, symbol: "ETH")
        case .bsc: TokenInfo(decimals: 18, name: "Binance Coin", isNative: true, symbol: "BNB")
        case .hyperEVM: TokenInfo(decimals: 18, name: "Hyperliquid", isNative: true, symbol: "HYPE")
        case .mantle: TokenInfo(decimals: 18, name: "Mantle", isNative: true, symbol: "MNT")
        case .monad: TokenInfo(decimals: 18, name: "Monad", isNative: true, symbol: "MON")
        case .polygon: TokenInfo(decimals: 18, name: "Polygon Ecosystem Token", isNative: true, symbol: "POL")

        case let .custom(chainId): TokenInfo(
            decimals: 18,
            name: "Chain-\(chainId) Ether",
            isNative: true,
            symbol: "ETH")
        }
    }

    var networkName: String {
        switch self {
        case let .arbitrum(network): network.name
        case let .avalanche(network): network.name
        case let .base(network): network.name
        case let .bsc(network): network.name
        case let .custom(chainId): "(\(chainId))"
        case let .ethereum(network): network.name
        case let .hyperEVM(network): network.name
        case let .mantle(network): network.name
        case let .monad(network): network.name
        case let .optimism(network): network.name
        case let .polygon(network): network.name
        case let .robinhood(network): network.name
        case let .unichain(network): network.name
        }
    }

    var rpcURL: URL {
        switch self {
        case let .arbitrum(network):
            switch network {
            case .mainnet: URL(string: "https://arbitrum-one-rpc.publicnode.com")!
            case .sepolia: URL(string: "https://arbitrum-sepolia-rpc.publicnode.com")!
            }

        case let .avalanche(network):
            switch network {
            case .fuji: URL(string: "https://avalanche-fuji-c-chain-rpc.publicnode.com")!
            case .mainnet: URL(string: "https://avalanche-c-chain-rpc.publicnode.com")!
            }

        case let .base(network):
            switch network {
            case .mainnet: URL(string: "https://base-rpc.publicnode.com")!
            case .sepolia: URL(string: "https://base-sepolia-rpc.publicnode.com")!
            }

        case let .bsc(network):
            switch network {
            case .mainnet: URL(string: "https://bsc-rpc.publicnode.com")!
            case .testnet: URL(string: "https://bsc-testnet-rpc.publicnode.com")!
            }

        case let .ethereum(network):
            switch network {
            case .mainnet: URL(string: "https://ethereum-rpc.publicnode.com")!
            case .sepolia: URL(string: "https://ethereum-sepolia-rpc.publicnode.com")!
            }

        case let .hyperEVM(network):
            switch network {
            case .mainnet: URL(string: "https://rpc.hyperliquid.xyz/evm")!
            case .testnet: URL(string: "https://rpc.hyperliquid-testnet.xyz/evm")!
            }

        case let .mantle(network):
            switch network {
            case .mainnet: URL(string: "https://rpc.mantle.xyz")!
            case .sepolia: URL(string: "https://rpc.sepolia.mantle.xyz")!
            }

        case let .monad(network):
            switch network {
            case .mainnet: URL(string: "https://rpc.monad.xyz")!
            case .testnet: URL(string: "https://testnet-rpc.monad.xyz")!
            }

        case let .optimism(network):
            switch network {
            case .mainnet: URL(string: "https://optimism-rpc.publicnode.com")!
            case .sepolia: URL(string: "https://optimism-sepolia-rpc.publicnode.com")!
            }

        case let .polygon(network):
            switch network {
            case .amoy: URL(string: "https://polygon-amoy-bor-rpc.publicnode.com")!
            case .mainnet: URL(string: "https://polygon-bor-rpc.publicnode.com")!
            }

        case let .robinhood(network):
            switch network {
            case .mainnet: URL(string: "https://rpc.mainnet.chain.robinhood.com")!
            case .testnet: URL(string: "https://rpc.testnet.chain.robinhood.com")!
            }

        case let .unichain(network):
            switch network {
            case .mainnet: URL(string: "https://unichain-rpc.publicnode.com")!
            case .sepolia: URL(string: "https://unichain-sepolia-rpc.publicnode.com")!
            }

        case .custom:
            URL(string: "https://localhost")!
        }
    }

    func isSameBlockchain(as other: EVMBlockchain) -> Bool {
        switch (self, other) {
        case (.arbitrum, .arbitrum),
             (.avalanche, .avalanche),
             (.base, .base),
             (.bsc, .bsc),
             (.ethereum, .ethereum),
             (.hyperEVM, .hyperEVM),
             (.mantle, .mantle),
             (.monad, .monad),
             (.optimism, .optimism),
             (.polygon, .polygon),
             (.robinhood, .robinhood),
             (.unichain, .unichain):
            true
        case let (.custom(chainId), .custom(otherChainId)):
            chainId == otherChainId
        default:
            false
        }
    }
}
