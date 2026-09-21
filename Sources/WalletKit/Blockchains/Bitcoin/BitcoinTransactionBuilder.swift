//
//  BitcoinTransactionBuilder.swift
//  WalletKit
//

import BigInt
import Foundation
import WalletKitRust

/// A ``BlockchainTransactionBuilderProtocol`` implementation for Bitcoin,
/// backed by a ``BitcoinClient``.
///
/// Builds unsigned PSBT bytes (via `bitcoin_build_unsigned_psbt`) ready
/// for ``BitcoinPKeySigner/sign(transaction:)`` — coin selection
/// (``BitcoinCoinSelector``) picks the inputs and decides whether a
/// change output is needed; the change address, when one is needed,
/// comes from the sender's resolver (a fresh, never-before-seen address
/// on the change chain).
public struct BitcoinTransactionBuilder: BlockchainTransactionBuilderProtocol {
    public typealias Address = BitcoinDescriptor

    private let client: BitcoinClient

    /// Creates a builder backed by `client`.
    public init(client: BitcoinClient) {
        self.client = client
    }

    /// Builds unsigned PSBT bytes for a transfer of `amount` sats from
    /// `sender` to `recipient`.
    ///
    /// - Parameters:
    ///   - sender: The account paying — its UTXOs are spent and, if
    ///     change is needed, a fresh change address on its change chain
    ///     receives it.
    ///   - recipient: The destination. Parses as a `.singleAddress`
    ///     descriptor wrapping the recipient's address (see
    ///     ``BitcoinDescriptor/init(string:)``); its `chain`/`index`
    ///     don't matter, since `deriveAddress(chain:index:)` on a
    ///     `.singleAddress` descriptor always returns its one address.
    ///   - amount: The transfer amount in sats.
    ///   - token: Must be `nil` — Bitcoin has no secondary tokens.
    ///   - options: `.bitcoinFeeOverride` overrides the fetched fee rate;
    ///     every other option is ignored.
    /// - Returns: Unsigned PSBT bytes, ready for
    ///   ``BitcoinPKeySigner/sign(transaction:)``.
    /// - Throws: ``BlockchainTransactionBuilderError/invalidToken(reason:)``
    ///   if `token` is non-nil; ``BlockchainTransactionBuilderError/amountTooLarge``
    ///   if `amount` exceeds `UInt64.max`;
    ///   ``BlockchainTransactionBuilderError/insufficientFunds(reason:)``
    ///   if `sender`'s UTXOs can't cover `amount` plus fees; or
    ///   ``BlockchainClientError`` on a backend failure.
    public func buildTransfer(
        sender: BitcoinDescriptor,
        recipient: BitcoinDescriptor,
        amount: BigUInt,
        token: String?,
        options: [BlockchainTransactionBuilderOptions]
    ) async throws -> Data {
        guard token == nil else {
            throw BlockchainTransactionBuilderError.invalidToken(reason: "Bitcoin has no secondary tokens")
        }
        guard let amountSats = UInt64(exactly: amount) else {
            throw BlockchainTransactionBuilderError.amountTooLarge
        }

        let feeRate: UInt64
        if let overrideRate = options.bitcoinFeeOverrideRate {
            feeRate = overrideRate
        } else {
            let estimated = try await client.backend.estimateFeeRate(blocks: 3)
            feeRate = UInt64(max(1, estimated.rounded(.up)))
        }

        let inputKind: BitcoinInputKindFfi = sender.scriptType == .p2tr ? .p2tr : .p2wpkh
        let recipientScript = try recipient.deriveAddress(chain: 0, index: 0).scriptPubkey()

        let resolver = await client.resolver(for: sender)
        let utxos = try await resolver.allUTXOs()

        let selection = try BitcoinCoinSelector.select(
            from: utxos,
            recipientScriptPubkey: recipientScript,
            targetSats: amountSats,
            feeRateSatPerVByte: feeRate,
            inputKind: inputKind,
            changeOutputKind: inputKind
        )

        var outputs = [BitcoinPsbtOutputFfi(scriptPubkey: recipientScript, valueSats: amountSats)]
        if selection.changeSats > 0 {
            let change = try await resolver.firstUnused(chain: 1)
            outputs.append(BitcoinPsbtOutputFfi(scriptPubkey: change.address.scriptPubkey(), valueSats: selection.changeSats))
        }

        let inputs = try selection.inputs.map { utxo in
            try BitcoinPsbtInputFfi(
                txid: utxo.txid,
                vout: utxo.vout,
                valueSats: utxo.valueSats,
                scriptPubkey: utxo.scriptPubkey,
                publicKey: sender.derivePublicKey(chain: utxo.chain, index: utxo.index),
                masterFingerprint: sender.masterFingerprint,
                derivationPath: "\(sender.accountPath)/\(utxo.chain)/\(utxo.index)",
                isTaproot: inputKind == .p2tr
            )
        }

        return try bitcoinBuildUnsignedPsbt(inputs: inputs, outputs: outputs, locktime: 0)
    }
}

private extension Array where Element == BlockchainTransactionBuilderOptions {
    /// Extracts the fee-rate override from the first `.bitcoinFeeOverride`
    /// with a non-nil rate, or `nil` if none was supplied — a
    /// `.bitcoinFeeOverride(feeRateSatPerVByte: nil)` is treated the same
    /// as the option being absent.
    var bitcoinFeeOverrideRate: UInt64? {
        for option in self {
            if case let .bitcoinFeeOverride(rate) = option, let rate {
                return rate
            }
        }
        return nil
    }
}
