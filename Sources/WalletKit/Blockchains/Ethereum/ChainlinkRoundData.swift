//
//  ChainlinkRoundData.swift
//  WalletKit
//
//  Created by Andrey Yurkevich on 20/08/2026.
//  Copyright © 2026 Reefr Wallet. All rights reserved.
//

import BigInt

/// Chainlink's `AggregatorV3Interface.latestRoundData()` return values —
/// the worked example for reading an on-chain oracle.
public struct ChainlinkRoundData {
    public let roundId: BigUInt
    public let answer: BigInt
    public let startedAt: BigUInt
    public let updatedAt: BigUInt
    public let answeredInRound: BigUInt
}
