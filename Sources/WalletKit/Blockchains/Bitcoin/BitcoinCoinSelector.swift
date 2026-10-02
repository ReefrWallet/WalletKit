//
//  BitcoinCoinSelector.swift
//  WalletKit
//

import Foundation
import WalletKitRust

/// Picks which UTXOs a transfer spends and whether it needs a change
/// output.
enum BitcoinCoinSelector {
    struct Selection {
        let inputs: [BitcoinUTXO]
        /// `0` when no change output is needed — either an exact/near-exact
        /// match was found, or the leftover after a greedy selection was
        /// below ``dustThresholdSats`` and got folded into the fee instead.
        let changeSats: UInt64
    }

    /// Below this, an output isn't worth creating — it would cost more to
    /// spend later (at any reasonable fee rate) than it's worth. Matches
    /// Bitcoin Core's default dust relay threshold for a P2WPKH output.
    static let dustThresholdSats: UInt64 = 546

    /// Selects UTXOs from `available` covering `targetSats` paid to
    /// `recipientScriptPubkey`, plus the fee (at `feeRateSatPerVByte`) for
    /// spending the selected inputs and both outputs.
    ///
    /// Tries every prefix of `available` sorted largest-first for a
    /// changeless match first — input total falls within `[target + fee,
    /// target + fee + dust)`, so no change output is needed at all, saving
    /// its vbytes — bounded to the first 32 prefixes considered (in the
    /// spirit of, but not a full implementation of, Bitcoin Core's
    /// branch-and-bound selector — an exhaustive subset search is a
    /// follow-up). Falls back to a largest-first greedy selection that
    /// always adds a change output, dropping that change into the fee
    /// instead of creating it if it would be dust.
    ///
    /// - Throws: ``BlockchainTransactionBuilderError/insufficientFunds(reason:)``
    ///   if `available`'s total, less fees, can't cover `targetSats`.
    static func select(
        from available: [BitcoinUTXO],
        recipientScriptPubkey: Data,
        targetSats: UInt64,
        feeRateSatPerVByte: UInt64,
        inputKind: BitcoinInputKindFfi,
        changeOutputKind: BitcoinInputKindFfi
    ) throws -> Selection {
        let sorted = available.sorted { $0.valueSats > $1.valueSats }

        if let exact = changelessMatch(
            sorted: sorted,
            recipientScriptPubkey: recipientScriptPubkey,
            targetSats: targetSats,
            feeRateSatPerVByte: feeRateSatPerVByte,
            inputKind: inputKind
        ) {
            return exact
        }

        var accumulated: UInt64 = 0
        var selected: [BitcoinUTXO] = []
        for utxo in sorted {
            selected.append(utxo)
            accumulated += utxo.valueSats

            let feeWithChange = fee(
                inputCount: selected.count,
                outputs: [recipientScriptPubkey, dummyScript(for: changeOutputKind)],
                feeRateSatPerVByte: feeRateSatPerVByte,
                inputKind: inputKind
            )
            guard accumulated >= targetSats + feeWithChange else {
                continue
            }

            let change = accumulated - targetSats - feeWithChange
            return Selection(inputs: selected, changeSats: change < dustThresholdSats ? 0 : change)
        }

        let total = sorted.reduce(0) { $0 + $1.valueSats }

        throw BlockchainTransactionBuilderError.insufficientFunds(
            reason: "need \(targetSats) sats plus fees but only \(total) sats available"
        )
    }

    // MARK: - Private

    private static func changelessMatch(
        sorted: [BitcoinUTXO],
        recipientScriptPubkey: Data,
        targetSats: UInt64,
        feeRateSatPerVByte: UInt64,
        inputKind: BitcoinInputKindFfi
    ) -> Selection? {
        var accumulated: UInt64 = 0
        var prefix: [BitcoinUTXO] = []

        for (attempt, utxo) in sorted.enumerated() {
            guard attempt < 32 else {
                break
            }

            prefix.append(utxo)
            accumulated += utxo.valueSats

            let feeWithoutChange = fee(
                inputCount: prefix.count,
                outputs: [recipientScriptPubkey],
                feeRateSatPerVByte: feeRateSatPerVByte,
                inputKind: inputKind
            )
            guard accumulated >= targetSats + feeWithoutChange else {
                continue
            }

            let excess = accumulated - targetSats - feeWithoutChange
            if excess < dustThresholdSats {
                return Selection(inputs: prefix, changeSats: 0)
            }
        }

        return nil
    }

    private static func fee(
        inputCount: Int,
        outputs: [Data],
        feeRateSatPerVByte: UInt64,
        inputKind: BitcoinInputKindFfi
    ) -> UInt64 {
        let vsize = bitcoinEstimateVsize(
            inputKinds: Array(repeating: inputKind, count: inputCount),
            outputScriptPubkeys: outputs
        )
        return vsize * feeRateSatPerVByte
    }

    /// A same-sized stand-in scriptPubkey for fee estimation before the
    /// real change address has been derived.
    private static func dummyScript(for kind: BitcoinInputKindFfi) -> Data {
        switch kind {
        case .p2wpkh: Data(count: 22) // OP_0 <push 20> + 20-byte hash.
        case .p2tr: Data(count: 34) // OP_1 <push 32> + 32-byte x-only key.
        }
    }
}
