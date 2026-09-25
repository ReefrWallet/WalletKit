//
//  EsploraClient.swift
//  WalletKit
//

import Foundation

/// A client for an Esplora-compatible REST API (blockstream.info,
/// mempool.space, self-hosted `electrs --http-addr`, ...). Plain HTTPS
/// JSON over `URLSession`, following the Ethereum client's shape rather than
/// introducing a new transport pattern — unlike
/// Electrum, Esplora needs nothing beyond what `URLSession` already gives.
struct EsploraClient: Sendable {
    let endpoint: URL
    let session: URLSession

    init(endpoint: URL, session: URLSession = .shared) {
        self.endpoint = endpoint
        self.session = session
    }

    struct AddressStats: Decodable {
        struct Stats: Decodable {
            let fundedTxoSum: UInt64
            let spentTxoSum: UInt64

            enum CodingKeys: String, CodingKey {
                case fundedTxoSum = "funded_txo_sum"
                case spentTxoSum = "spent_txo_sum"
            }
        }

        let chainStats: Stats
        let mempoolStats: Stats

        enum CodingKeys: String, CodingKey {
            case chainStats = "chain_stats"
            case mempoolStats = "mempool_stats"
        }
    }

    struct TxOut: Decodable {
        let scriptpubkey: String
        let value: UInt64
    }

    struct Vin: Decodable {
        let prevout: TxOut?
    }

    struct TxStatus: Decodable {
        let confirmed: Bool
        let blockHeight: UInt64?
        let blockTime: UInt64?

        enum CodingKeys: String, CodingKey {
            case confirmed
            case blockHeight = "block_height"
            case blockTime = "block_time"
        }
    }

    struct Transaction: Decodable {
        let txid: String
        let vin: [Vin]
        let vout: [TxOut]
        let status: TxStatus
    }

    struct Utxo: Decodable {
        let txid: String
        let vout: UInt32
        let value: UInt64
        let status: TxStatus
    }

    /// `GET /address/:address` — confirmed and mempool funded/spent sums.
    func addressStats(_ address: String) async throws -> AddressStats {
        try await get("address/\(address)")
    }

    /// `GET /address/:address/txs` — the first page: unconfirmed plus the
    /// most recent 25 confirmed transactions, newest first.
    func addressTransactions(_ address: String) async throws -> [Transaction] {
        try await get("address/\(address)/txs")
    }

    /// `GET /address/:address/txs/chain/:lastSeenTxid` — the next page of
    /// confirmed transactions after `lastSeenTxid`, 25 at a time, newest
    /// first. Esplora only paginates confirmed history this way; the
    /// first page (``addressTransactions``) already includes everything
    /// unconfirmed.
    func addressTransactions(_ address: String, after lastSeenTxid: String) async throws -> [Transaction] {
        try await get("address/\(address)/txs/chain/\(lastSeenTxid)")
    }

    /// `GET /address/:address/utxo`.
    func addressUtxos(_ address: String) async throws -> [Utxo] {
        try await get("address/\(address)/utxo")
    }

    /// `GET /tx/:txid`.
    func transaction(_ txid: String) async throws -> Transaction {
        try await get("tx/\(txid)")
    }

    /// `GET /tx/:txid/hex` — the raw consensus-serialized transaction,
    /// hex-encoded plain text (not JSON).
    func rawTransaction(_ txid: String) async throws -> Data {
        let request = URLRequest(url: endpoint.appendingPathComponent("tx/\(txid)/hex"))
        let (data, response) = try await perform(request)
        try Self.validate(response, data: data)
        guard let hex = String(data: data, encoding: .utf8) else {
            throw BlockchainClientError.decodingFailed(reason: "raw transaction response is not UTF-8 text")
        }
        return try Data(hexString: hex.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    /// `GET /fee-estimates` — a `{"1": 87.882, "2": 45.2, ...}` map from
    /// confirmation-target block count to fee rate in sat/vB.
    func feeEstimates() async throws -> [String: Double] {
        try await get("fee-estimates")
    }

    /// `GET /blocks/tip/height` — the current chain tip height, plain
    /// text (not JSON).
    func tipHeight() async throws -> UInt64 {
        let request = URLRequest(url: endpoint.appendingPathComponent("blocks/tip/height"))
        let (data, response) = try await perform(request)
        try Self.validate(response, data: data)
        guard let text = String(data: data, encoding: .utf8),
              let height = UInt64(text.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            throw BlockchainClientError.decodingFailed(reason: "malformed /blocks/tip/height response")
        }
        return height
    }

    /// `POST /tx` — broadcasts `rawTransactionHex` (lowercase hex) and
    /// returns the resulting txid.
    func broadcast(rawTransactionHex: String) async throws -> String {
        var request = URLRequest(url: endpoint.appendingPathComponent("tx"))
        request.httpMethod = "POST"
        request.httpBody = Data(rawTransactionHex.utf8)

        let (data, response) = try await perform(request)
        try Self.validate(response, data: data)
        guard let txid = String(data: data, encoding: .utf8) else {
            throw BlockchainClientError.decodingFailed(reason: "broadcast response is not UTF-8 text")
        }
        return txid.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - Private helpers

    private func get<T: Decodable>(_ path: String) async throws -> T {
        let request = URLRequest(url: endpoint.appendingPathComponent(path))
        let (data, response) = try await perform(request)
        try Self.validate(response, data: data)

        do {
            // Every snake_case JSON field already has an explicit
            // `CodingKeys` mapping below — no `keyDecodingStrategy`
            // needed (and combining one with explicit raw string keys
            // would double-transform and fail to match).
            return try JSONDecoder().decode(T.self, from: data)
        } catch {
            throw BlockchainClientError.decodingFailed(reason: "\(error)")
        }
    }

    private func perform(_ request: URLRequest) async throws -> (Data, URLResponse) {
        do {
            return try await session.data(for: request)
        } catch {
            throw BlockchainClientError.transportError(reason: error.localizedDescription)
        }
    }

    private static func validate(_ response: URLResponse, data: Data) throws {
        guard let http = response as? HTTPURLResponse else {
            throw BlockchainClientError.invalidResponse(reason: "not an HTTP response")
        }
        guard (200 ..< 300).contains(http.statusCode) else {
            let body = String(data: data, encoding: .utf8) ?? ""
            throw BlockchainClientError.invalidResponse(reason: "HTTP \(http.statusCode): \(body)")
        }
    }
}

private extension URLSession {
    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        try await data(for: request, delegate: nil)
    }
}
