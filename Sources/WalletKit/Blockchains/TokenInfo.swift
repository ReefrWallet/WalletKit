//
//  TokenInfo.swift
//  WalletKit
//
//  Created by Andrey Yurkevich on 22/08/2026.
//  Copyright © 2026 Reefr Wallet. All rights reserved.
//

import Foundation

public struct TokenInfo {
    public let address: String? = nil
    public let decimals: UInt8
    public let name: String
    public let isNative: Bool
    public let symbol: String
}

public extension TokenInfo {
    static let ada = TokenInfo(decimals: 6, name: "Ada", isNative: true, symbol: "ADA")
    static let aptos = TokenInfo(decimals: 8, name: "Aptos", isNative: true, symbol: "APT")
    static let bitcoin = TokenInfo(decimals: 8, name: "Bitcoin", isNative: true, symbol: "BTC")
    static let solana = TokenInfo(decimals: 9, name: "Solana", isNative: true, symbol: "SOL")
    static let sui = TokenInfo(decimals: 9, name: "Sui", isNative: true, symbol: "SUI")
    static let tron = TokenInfo(decimals: 6, name: "Tron", isNative: true, symbol: "TRX")
}
