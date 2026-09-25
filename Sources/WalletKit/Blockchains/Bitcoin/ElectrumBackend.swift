//
//  ElectrumBackend.swift
//  WalletKit
//

import Foundation
import WalletKitRust

/// Internal Bitcoin backend backed by an Electrum client.
struct ElectrumBackend: BitcoinBackend {
    let client: ElectrumClient

    init(host: String, port: UInt16, useTLS: Bool) {
        client = ElectrumClient(connection: ElectrumConnection(host: host, port: port, useTLS: useTLS))
    }

    func balance(of address: BitcoinAddressFfi) async throws -> (confirmed: UInt64, unconfirmed: Int64) {
        let balance = try await client.balance(scripthash: scripthash(of: address))
        // `confirmed` is a balance, never legitimately negative on a
        // well-formed server response.
        return (confirmed: UInt64(max(0, balance.confirmed)), unconfirmed: balance.unconfirmed)
    }

    func history(of address: BitcoinAddressFfi) async throws -> [BitcoinBackendHistoryEntry] {
        let entries = try await client.history(scripthash: scripthash(of: address))
        return entries.map { BitcoinBackendHistoryEntry(txid: $0.txid, height: $0.height) }
    }

    func utxos(of address: BitcoinAddressFfi, chain: UInt32, index: UInt32) async throws -> [BitcoinUTXO] {
        let scriptPubkey = address.scriptPubkey()
        let unspent = try await client.listUnspent(scripthash: scripthash(of: address))
        return unspent.map { entry in
            BitcoinUTXO(
                txid: entry.txid,
                vout: entry.vout,
                valueSats: entry.valueSats,
                scriptPubkey: scriptPubkey,
                chain: chain,
                index: index,
                confirmed: entry.height != nil
            )
        }
    }

    /// Hydrates each input's spent value/scriptPubkey by looking up its
    /// own previous transaction — decoding a raw transaction ourselves
    /// (see ``ElectrumClient/transaction(txid:)``) gives each input's
    /// `(txid, vout)` but not what it spent, unlike Esplora's
    /// `vin[].prevout`. This costs one extra round trip per input; a
    /// persistent cache of the account's own previously seen outputs
    /// would avoid it for our own UTXOs, but isn't implemented yet.
    func transaction(txid: String) async throws -> BitcoinBackendTransaction {
        let decoded = try await client.transaction(txid: txid)

        var inputs: [(scriptPubkey: Data, valueSats: UInt64)] = []
        for input in decoded.inputs {
            let previous = try await client.transaction(txid: input.txid)
            guard input.vout < previous.outputs.count else {
                throw BlockchainClientError.decodingFailed(reason: "input vout out of range for its previous transaction")
            }
            let spentOutput = previous.outputs[Int(input.vout)]
            inputs.append((scriptPubkey: try Data(hexString: spentOutput.scriptPubkeyHex), valueSats: spentOutput.valueSats))
        }

        let outputs = try decoded.outputs.map { output in
            (scriptPubkey: try Data(hexString: output.scriptPubkeyHex), valueSats: output.valueSats)
        }

        // Decoding the raw transaction ourselves (rather than trusting
        // the server's verbose JSON — see ``ElectrumClient/transaction(txid:)``
        // for why) gives no confirmation count or block time at all —
        // callers needing either should prefer
        // `blockchain.scripthash.get_history`'s own entry (for height) or
        // do without (Electrum has no timestamp source outside a block
        // header fetch, not implemented here).
        return BitcoinBackendTransaction(txid: decoded.txid, height: nil, blockTime: nil, inputs: inputs, outputs: outputs)
    }

    func rawTransaction(txid: String) async throws -> Data {
        try await client.rawTransaction(txid: txid)
    }

    func estimateFeeRate(blocks: Int) async throws -> Double {
        try await client.estimateFee(blocks: blocks)
    }

    func broadcast(rawTransaction: Data) async throws -> String {
        try await client.broadcast(rawTransactionHex: rawTransaction.bitcoinHexEncoded)
    }

    /// `blockchain.headers.subscribe` — idempotent to call repeatedly (it
    /// just reports the server's current tip each time), so reusing it
    /// here doesn't interfere with ``headsStream()``'s own subscription.
    func currentHeight() async throws -> UInt64 {
        try await client.subscribeHeaders()
    }

    func headsStream() -> AsyncThrowingStream<BlockchainTransactionHead, any Swift.Error> {
        AsyncThrowingStream { continuation in
            Task {
                do {
                    let height = try await client.subscribeHeaders()
                    continuation.yield(BlockchainTransactionHead(height: height))
                    await client.connection.onNotification(method: "blockchain.headers.subscribe") { params in
                        guard let array = params as? [[String: Any]], let first = array.first,
                              let height = (first["height"] as? NSNumber)?.uint64Value else { return }
                        continuation.yield(BlockchainTransactionHead(height: height, hash: first["hex"] as? String))
                    }
                } catch {
                    continuation.finish(throwing: error)
                }
            }
        }
    }

    private func scripthash(of address: BitcoinAddressFfi) -> String {
        ElectrumClient.scripthash(scriptPubkey: address.scriptPubkey())
    }
}
