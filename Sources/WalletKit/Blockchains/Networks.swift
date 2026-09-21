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
/// setting (like ``Networks/BitcoinNetwork/rpcURL``, only set at account
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

    public static var allNetworks: [WKBlockchain] {
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

    /// The default Electrum endpoint — kept as the pre-existing `rpcURL`
    /// name so call sites that don't yet know about ``BitcoinBackendKind``
    /// keep compiling. New call sites should prefer
    /// ``defaultEndpoint(for:)``.
    public var rpcURL: URL {
        defaultEndpoint(for: .electrum)
    }

    /// The default endpoint for `backend` on this network. A placeholder
    /// today, like every other chain's `rpcURL` in this file — real
    /// public Electrum/Esplora endpoints need curating (and load-testing
    /// before defaulting production traffic to them) before this ships;
    /// until then every Bitcoin account should set a custom endpoint via
    /// `AddAccountView`'s existing override field.
    public func defaultEndpoint(for backend: BitcoinBackendKind) -> URL {
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
