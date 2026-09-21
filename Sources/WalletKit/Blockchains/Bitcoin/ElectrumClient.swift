//
//  ElectrumClient.swift
//  WalletKit
//

import Foundation
import CryptoKit

/// Typed wrappers over ``ElectrumConnection``'s raw JSON-RPC calls, for
/// the subset of the Electrum protocol this crate needs.
struct ElectrumClient: Sendable {
    let connection: ElectrumConnection

    init(connection: ElectrumConnection) {
        self.connection = connection
    }

    struct Balance {
        let confirmed: Int64
        let unconfirmed: Int64
    }

    struct HistoryEntry {
        let txid: String
        /// `nil` for unconfirmed; Electrum reports these as height `0` or
        /// negative (negative means "has an unconfirmed parent").
        let height: UInt64?
    }

    struct Unspent {
        let txid: String
        let vout: UInt32
        let height: UInt64?
        let valueSats: UInt64
    }

    struct DecodedOutput {
        let scriptPubkeyHex: String
        let valueSats: UInt64
    }

    struct DecodedInput {
        let txid: String
        let vout: UInt32
    }

    struct DecodedTransaction {
        let txid: String
        let confirmations: UInt64?
        let blockTime: UInt64?
        let inputs: [DecodedInput]
        let outputs: [DecodedOutput]
    }

    /// `blockchain.scripthash.get_balance`.
    func balance(scripthash: String) async throws -> Balance {
        let result = try await connection.call(method: "blockchain.scripthash.get_balance", params: [scripthash])
        guard let dictionary = result as? [String: Any],
              let confirmed = (dictionary["confirmed"] as? NSNumber)?.int64Value,
              let unconfirmed = (dictionary["unconfirmed"] as? NSNumber)?.int64Value else {
            throw BlockchainClientError.decodingFailed(reason: "malformed get_balance response")
        }
        return Balance(confirmed: confirmed, unconfirmed: unconfirmed)
    }

    /// `blockchain.scripthash.get_history` — the address's full history in
    /// one call (no native pagination, unlike Esplora).
    func history(scripthash: String) async throws -> [HistoryEntry] {
        let result = try await connection.call(method: "blockchain.scripthash.get_history", params: [scripthash])
        guard let array = result as? [[String: Any]] else {
            throw BlockchainClientError.decodingFailed(reason: "malformed get_history response")
        }
        return try array.map { entry in
            guard let txid = entry["tx_hash"] as? String, let height = (entry["height"] as? NSNumber)?.int64Value else {
                throw BlockchainClientError.decodingFailed(reason: "malformed get_history entry")
            }
            return HistoryEntry(txid: txid, height: height > 0 ? UInt64(height) : nil)
        }
    }

    /// `blockchain.scripthash.listunspent`.
    func listUnspent(scripthash: String) async throws -> [Unspent] {
        let result = try await connection.call(method: "blockchain.scripthash.listunspent", params: [scripthash])
        guard let array = result as? [[String: Any]] else {
            throw BlockchainClientError.decodingFailed(reason: "malformed listunspent response")
        }
        return try array.map { entry in
            guard let txid = entry["tx_hash"] as? String,
                  let vout = (entry["tx_pos"] as? NSNumber)?.uint32Value,
                  let height = (entry["height"] as? NSNumber)?.int64Value,
                  let value = (entry["value"] as? NSNumber)?.uint64Value else {
                throw BlockchainClientError.decodingFailed(reason: "malformed listunspent entry")
            }
            return Unspent(txid: txid, vout: vout, height: height > 0 ? UInt64(height) : nil, valueSats: value)
        }
    }

    /// `blockchain.transaction.get` with `verbose: true` — a bitcoind-style
    /// decoded transaction. Unlike Esplora, this gives each input's own
    /// `(txid, vout)` but not the value/scriptPubkey it spent — callers
    /// needing that must look up the referenced previous transaction
    /// themselves (see ``ElectrumBackend/transaction(txid:)``).
    func transaction(txid: String) async throws -> DecodedTransaction {
        let result = try await connection.call(method: "blockchain.transaction.get", params: [txid, true])
        guard let dictionary = result as? [String: Any] else {
            throw BlockchainClientError.decodingFailed(reason: "malformed transaction.get response")
        }

        let vin = dictionary["vin"] as? [[String: Any]] ?? []
        let inputs: [DecodedInput] = vin.compactMap { entry in
            guard let inputTxid = entry["txid"] as? String, let vout = (entry["vout"] as? NSNumber)?.uint32Value else {
                return nil // coinbase input — no `txid`/`vout` to reference.
            }
            return DecodedInput(txid: inputTxid, vout: vout)
        }

        let vout = dictionary["vout"] as? [[String: Any]] ?? []
        let outputs: [DecodedOutput] = try vout.map { entry in
            guard let scriptPubkey = entry["scriptPubKey"] as? [String: Any],
                  let scriptHex = scriptPubkey["hex"] as? String,
                  let value = entry["value"] as? NSNumber else {
                throw BlockchainClientError.decodingFailed(reason: "malformed transaction.get output")
            }
            // Electrum reports `value` in whole BTC (a decimal), not sats.
            let valueSats = (value.doubleValue * 100_000_000).rounded()
            return DecodedOutput(scriptPubkeyHex: scriptHex, valueSats: UInt64(valueSats))
        }

        return DecodedTransaction(
            txid: dictionary["txid"] as? String ?? txid,
            confirmations: (dictionary["confirmations"] as? NSNumber)?.uint64Value,
            blockTime: (dictionary["blocktime"] as? NSNumber)?.uint64Value,
            inputs: inputs,
            outputs: outputs
        )
    }

    /// `blockchain.transaction.broadcast`.
    func broadcast(rawTransactionHex: String) async throws -> String {
        let result = try await connection.call(method: "blockchain.transaction.broadcast", params: [rawTransactionHex])
        guard let txid = result as? String else {
            throw BlockchainClientError.decodingFailed(reason: "malformed broadcast response")
        }
        return txid
    }

    /// `blockchain.estimatefee` — BTC per kilobyte; converted to sat/vB.
    func estimateFee(blocks: Int) async throws -> Double {
        let result = try await connection.call(method: "blockchain.estimatefee", params: [blocks])
        guard let btcPerKvB = (result as? NSNumber)?.doubleValue else {
            throw BlockchainClientError.decodingFailed(reason: "malformed estimatefee response")
        }
        guard btcPerKvB > 0 else { return 0 }
        return btcPerKvB * 100_000_000 / 1_000
    }

    /// `blockchain.headers.subscribe` — the initial response only; the
    /// server's follow-up push notifications are routed separately via
    /// ``ElectrumConnection/onNotification(method:handler:)``.
    func subscribeHeaders() async throws -> UInt64 {
        let result = try await connection.call(method: "blockchain.headers.subscribe", params: [])
        guard let dictionary = result as? [String: Any], let height = (dictionary["height"] as? NSNumber)?.uint64Value else {
            throw BlockchainClientError.decodingFailed(reason: "malformed headers.subscribe response")
        }
        return height
    }

    /// The Electrum scripthash for `scriptPubkey`: SHA-256, byte-reversed,
    /// lowercase hex.
    static func scripthash(scriptPubkey: Data) -> String {
        let digest = SHA256.hash(data: scriptPubkey)
        return Data(digest).reversed().map { String(format: "%02x", $0) }.joined()
    }
}
