//
//  Networks.swift
//  WalletKit
//
//  Created by Andrey Yurkevich on 25/08/2026.
//  Copyright © 2026 Reefr Wallet. All rights reserved.
//

import Foundation
import WalletKitRust

/// Which indexing backend a Bitcoin account talks to — a per-account
/// setting (like ``BitcoinNetwork/rpcURL``, only set at account
/// creation) rather than a chain-wide constant, since both are viable and
/// neither is universally better: Electrum supports push subscriptions
/// (``BlockchainClientFeature/transactionSubscription``), Esplora is a
/// simpler REST API with no server push.
public enum BitcoinBackendKind: String, Codable, CaseIterable, Sendable {
    case electrum
    case esplora
}

public enum BitcoinNetwork: Codable, Equatable, Hashable, Sendable {
    case mainnet
    case testnet
    case signet
    case regtest

    public static var allNetworks: [Blockchain] {
        [.bitcoin(.mainnet), .bitcoin(.testnet), .bitcoin(.signet), .bitcoin(.regtest)]
    }

    public var name: String {
        switch self {
        case .mainnet: "Mainnet"
        case .testnet: "Testnet"
        case .signet: "Signet"
        case .regtest: "Regtest"
        }
    }

    var raw: BitcoinNetworkFfi {
        switch self {
        case .mainnet: .mainnet
        case .testnet: .testnet
        case .signet: .signet
        case .regtest: .regtest
        }
    }

    /// The default Electrum endpoint.
    public var rpcURL: URL {
        defaultEndpoint(for: .electrum)
    }

    /// The default public endpoint for `backend` on this network.
    ///
    /// Provide a private endpoint when privacy or reliability requirements
    /// demand it. Regtest returns a local placeholder endpoint.
    public func defaultEndpoint(for backend: BitcoinBackendKind) -> URL {
        switch (self, backend) {
        case (.mainnet, .electrum):
            URL(string: "ssl://electrum.blockstream.info:50002")!
        case (.mainnet, .esplora):
            URL(string: "https://blockstream.info/api")!
        case (.testnet, .electrum):
            URL(string: "ssl://electrum.blockstream.info:60002")!
        case (.testnet, .esplora):
            URL(string: "https://blockstream.info/testnet/api")!
        case (.signet, .electrum):
            URL(string: "ssl://signet-electrumx.wakiyamap.dev:50002")!
        case (.signet, .esplora):
            URL(string: "https://blockstream.info/signet/api")!
        case (.regtest, _):
            URL(string: "https://localhost")!
        }
    }
}

public enum CardanoNetwork: Codable, Equatable, Hashable, Sendable {
    case mainnet
    case preprod

    public static var allNetworks: [Blockchain] {
        [.cardano(.mainnet), .cardano(.preprod)]
    }

    public var name: String {
        switch self {
        case .mainnet: "Mainnet"
        case .preprod: "Preprod"
        }
    }

    public var addressNetworkId: UInt8 {
        self == .mainnet ? 1 : 0
    }

    public var rpcURL: URL {
        switch self {
        case .mainnet:
            URL(string: "https://cardano-mainnet.blockfrost.io/api/v0")!
        case .preprod:
            URL(string: "https://cardano-preprod.blockfrost.io/api/v0")!
        }
    }

    public var storageIdentifier: String {
        switch self {
        case .mainnet: "mainnet"
        case .preprod: "preprod"
        }
    }

    init?(storageIdentifier: String) {
        switch storageIdentifier {
        case "mainnet":
            self = .mainnet
        case "preprod":
            self = .preprod
        default:
            return nil
        }
    }
}

public enum SolanaNetwork: Codable, Equatable, Hashable, Sendable {
    case mainnet
    case testnet
    case devnet

    public static var allNetworks: [Blockchain] {
        [.solana(.mainnet), .solana(.testnet), .solana(.devnet)]
    }

    public var name: String {
        switch self {
        case .mainnet: "Mainnet"
        case .testnet: "Testnet"
        case .devnet: "Devnet"
        }
    }

    /// The cluster's public RPC endpoint.
    public var rpcURL: URL {
        switch self {
        case .mainnet:
            URL(string: "https://api.mainnet-beta.solana.com")!
        case .testnet:
            URL(string: "https://api.testnet.solana.com")!
        case .devnet:
            URL(string: "https://api.devnet.solana.com")!
        }
    }
}

public enum TronNetwork: Codable, Equatable, Hashable, Sendable {
    case mainnet
    case testnet

    public static var allNetworks: [Blockchain] {
        [.tron(.mainnet), .tron(.testnet)]
    }

    public var name: String {
        switch self {
        case .mainnet: "Mainnet"
        case .testnet: "Nile"
        }
    }

    public var rpcURL: URL {
        switch self {
        case .mainnet:
            URL(string: "https://api.trongrid.io")!
        case .testnet:
            URL(string: "https://nile.trongrid.io")!
        }
    }

    /// TronScan API, the source for internal transfers TronGrid doesn't index.
    public var tronScanURL: URL {
        switch self {
        case .mainnet:
            URL(string: "https://apilist.tronscanapi.com")!
        case .testnet:
            URL(string: "https://nileapi.tronscan.org")!
        }
    }
}
