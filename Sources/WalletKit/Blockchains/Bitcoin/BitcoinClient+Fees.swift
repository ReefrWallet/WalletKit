//
//  BitcoinClient+Fees.swift
//  WalletKit
//
//  Created by Andrey Yurkevich on 06/10/2026.
//  Copyright © 2026 Reefr Wallet. All rights reserved.
//

import Foundation
import WalletKitRust

public extension BitcoinClient {
    /// Current fee rate for confirmation within 3 blocks, in sat/vB
    /// (at least 1).
    ///
    /// - Throws: ``BlockchainClientError`` on a backend failure.
    nonisolated func feeRate() async throws -> UInt64 {
        let feeRate = try await backend.estimateFeeRate(blocks: 3)
        return UInt64(max(1, feeRate.rounded(.up)))
    }

    /// The fee, in sats, implied by an unsigned `psbt` (inputs − outputs) —
    /// e.g. one built by ``BitcoinTransactionBuilder``.
    ///
    /// - Throws: ``WalletKitError`` if `psbt` can't be parsed.
    nonisolated func fee(psbt: Data) throws -> UInt64 {
        try remappingWalletKitError { try bitcoinPsbtFee(psbt: psbt) }
    }
}
