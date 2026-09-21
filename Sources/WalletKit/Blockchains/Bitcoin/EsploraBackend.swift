//
//  EsploraBackend.swift
//  WalletKit
//

import Foundation
import WalletKitRust

/// ``BitcoinBackend`` conformance backed by ``EsploraClient``. No push
/// transport exists in the Esplora API, so ``headsStream()`` resolves
/// immediately with ``WalletKitError/unsupportedFeature``.
struct EsploraBackend: BitcoinBackend {
    let client: EsploraClient

    init(endpoint: URL, session: URLSession = .shared) {
        client = EsploraClient(endpoint: endpoint, session: session)
    }

    func balance(of address: BitcoinAddressFfi) async throws -> (confirmed: UInt64, unconfirmed: Int64) {
        let stats = try await client.addressStats(address.string())
        let confirmed = stats.chainStats.fundedTxoSum - stats.chainStats.spentTxoSum
        let unconfirmedDelta = Int64(stats.mempoolStats.fundedTxoSum) - Int64(stats.mempoolStats.spentTxoSum)
        return (confirmed: confirmed, unconfirmed: unconfirmedDelta)
    }

    /// Walks every confirmed page via `/txs/chain/:lastSeenTxid` after the
    /// first `/txs` call (which already includes everything unconfirmed),
    /// stopping once a page returns fewer than 25 results — Esplora's own
    /// paging convention.
    func history(of address: BitcoinAddressFfi) async throws -> [BitcoinBackendHistoryEntry] {
        let addressString = address.string()
        var entries: [BitcoinBackendHistoryEntry] = []

        let firstPage = try await client.addressTransactions(addressString)
        entries.append(contentsOf: firstPage.map { BitcoinBackendHistoryEntry(txid: $0.txid, height: $0.status.blockHeight) })

        var cursor = firstPage.count < 25 ? nil : firstPage.last?.txid
        while let lastSeenTxid = cursor {
            let page = try await client.addressTransactions(addressString, after: lastSeenTxid)
            guard !page.isEmpty else { break }
            entries.append(contentsOf: page.map { BitcoinBackendHistoryEntry(txid: $0.txid, height: $0.status.blockHeight) })
            cursor = page.count < 25 ? nil : page.last?.txid
        }

        return entries
    }

    func utxos(of address: BitcoinAddressFfi, chain: UInt32, index: UInt32) async throws -> [BitcoinUTXO] {
        let scriptPubkey = address.scriptPubkey()
        let raw = try await client.addressUtxos(address.string())
        return raw.map { utxo in
            BitcoinUTXO(
                txid: utxo.txid,
                vout: utxo.vout,
                valueSats: utxo.value,
                scriptPubkey: scriptPubkey,
                chain: chain,
                index: index,
                confirmed: utxo.status.confirmed
            )
        }
    }

    func transaction(txid: String) async throws -> BitcoinBackendTransaction {
        let tx = try await client.transaction(txid)

        let inputs: [(scriptPubkey: Data, valueSats: UInt64)] = try tx.vin.map { input in
            // A coinbase input has no real prevout to attribute value to.
            guard let prevout = input.prevout else { return (scriptPubkey: Data(), valueSats: 0) }
            return (scriptPubkey: try Data(hexString: prevout.scriptpubkey), valueSats: prevout.value)
        }
        let outputs: [(scriptPubkey: Data, valueSats: UInt64)] = try tx.vout.map { output in
            (scriptPubkey: try Data(hexString: output.scriptpubkey), valueSats: output.value)
        }
        let blockTime = tx.status.blockTime.map { Date(timeIntervalSince1970: TimeInterval($0)) }

        return BitcoinBackendTransaction(
            txid: tx.txid,
            height: tx.status.blockHeight,
            blockTime: blockTime,
            inputs: inputs,
            outputs: outputs
        )
    }

    func rawTransaction(txid: String) async throws -> Data {
        try await client.rawTransaction(txid)
    }

    /// `/fee-estimates` doesn't guarantee an entry for every block-count
    /// key, so this falls back to the smallest available target at or
    /// above `blocks`, then to the single lowest target available at all.
    func estimateFeeRate(blocks: Int) async throws -> Double {
        let estimates = try await client.feeEstimates()
        if let exact = estimates["\(blocks)"] {
            return exact
        }

        let availableTargets = estimates.keys.compactMap { Int($0) }.sorted()
        guard let fallbackTarget = availableTargets.first(where: { $0 >= blocks }) ?? availableTargets.first,
              let value = estimates["\(fallbackTarget)"] else {
            throw BlockchainClientError.decodingFailed(reason: "fee-estimates response has no usable entry")
        }
        return value
    }

    func broadcast(rawTransaction: Data) async throws -> String {
        try await client.broadcast(rawTransactionHex: rawTransaction.hexEncoded)
    }

    func headsStream() -> AsyncThrowingStream<BlockchainTransactionHead, any Swift.Error> {
        AsyncThrowingStream { continuation in
            continuation.finish(throwing: WalletKitError.unsupportedFeature)
        }
    }
}
