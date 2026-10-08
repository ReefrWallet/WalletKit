//
//  EsploraClient.swift
//  WalletKit
//

import Alamofire
import Foundation
import Moya
import WalletKitRust

/// A client for an Esplora-compatible REST API (blockstream.info,
/// mempool.space, self-hosted `electrs --http-addr`, ...).
///
/// Rate-limit handling (retrying 429/503 with backoff, proactive pacing
/// where a confirmed rate is configured) comes from ``RateGateRegistry``,
/// shared process-wide and looked up by this client's own endpoint — the
/// public default (blockstream.info) and a self-hosted instance are
/// different origins and don't throttle each other.
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
        let data = try await requestData(.get(endpoint: endpoint, path: "tx/\(txid)/hex"))
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
        let data = try await requestData(.get(endpoint: endpoint, path: "blocks/tip/height"))
        guard let text = String(data: data, encoding: .utf8),
              let height = UInt64(text.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            throw BlockchainClientError.decodingFailed(reason: "malformed /blocks/tip/height response")
        }

        return height
    }

    /// `POST /tx` — broadcasts `rawTransactionHex` (lowercase hex) and
    /// returns the resulting txid.
    func broadcast(rawTransactionHex: String) async throws -> String {
        do {
            let data = try await requestData(.postPlainText(endpoint: endpoint, path: "tx", body: rawTransactionHex))
            guard let txid = String(data: data, encoding: .utf8) else {
                throw BlockchainClientError.decodingFailed(reason: "broadcast response is not UTF-8 text")
            }

            return txid.trimmingCharacters(in: .whitespacesAndNewlines)
        } catch let BlockchainClientError.invalidResponse(reason) where Self.looksLikeAlreadyKnown(reason) {
            // A 429/503 retry can land on this after the first attempt
            // actually landed. Unlike the node's txid, the canonical txid
            // is deterministic from the raw bytes — decode locally (via
            // the same FFI call `ElectrumClient` uses) rather than
            // trusting a possibly-inconsistent second response. Not a hash
            // of the raw bytes directly: that would be the SegWit wtxid.
            let raw = try Data(hexString: rawTransactionHex)
            return try bitcoinDecodeTransaction(raw: raw).txid
        }
    }

    // MARK: - Private helpers

    private func get<T: Decodable>(_ path: String) async throws -> T {
        let data = try await requestData(.get(endpoint: endpoint, path: path))

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

    private func requestData(_ target: EsploraAPI) async throws -> Data {
        let policy = RateGateRegistry.shared.makeRetryPolicy(for: origin, provider: .esplora)
        let afSession = Session(configuration: session.configuration, interceptor: policy)
        let provider = MoyaProvider<EsploraAPI>(session: afSession)

        do {
            return try await provider.requestData(target)
        } catch let error as MoyaError {
            throw Self.mapError(error)
        }
    }

    /// `origin`: scheme + host + explicit port only (not a default one) —
    /// matches ``RateGateRegistry``'s keying.
    private var origin: String {
        var components = URLComponents()
        components.scheme = endpoint.scheme
        components.host = endpoint.host
        components.port = endpoint.port
        return components.string ?? endpoint.absoluteString
    }

    private static func mapError(_ error: MoyaError) -> BlockchainClientError {
        switch error {
        case let .statusCode(response):
            return invalidResponse(response)
        case let .underlying(underlying, response):
            guard let response else {
                return .transportError(reason: underlying.localizedDescription)
            }

            return invalidResponse(response)
        default:
            return .transportError(reason: error.localizedDescription)
        }
    }

    private static func invalidResponse(_ response: Moya.Response) -> BlockchainClientError {
        let body = String(data: response.data, encoding: .utf8) ?? ""
        return .invalidResponse(reason: "HTTP \(response.statusCode): \(body)")
    }

    private static func looksLikeAlreadyKnown(_ reason: String) -> Bool {
        // Bitcoin Core's mempool reject reason is hyphenated
        // ("txn-already-known"); its already-confirmed rejection reads as
        // a normal sentence ("Transaction already in block chain").
        // Esplora/electrs-based backends generally proxy one of these
        // verbatim.
        ["already-known", "already known", "already in block chain", "already have transaction"].contains {
            reason.localizedCaseInsensitiveContains($0)
        }
    }
}

private enum EsploraAPI: TargetType {
    case get(endpoint: URL, path: String)
    case postPlainText(endpoint: URL, path: String, body: String)

    var baseURL: URL {
        switch self {
        case let .get(endpoint, _), let .postPlainText(endpoint, _, _): endpoint
        }
    }

    var path: String {
        switch self {
        case let .get(_, path), let .postPlainText(_, path, _): path
        }
    }

    var method: Moya.Method {
        switch self {
        case .get: .get
        case .postPlainText: .post
        }
    }

    var headers: [String: String]? { nil }

    var task: Moya.Task {
        switch self {
        case .get: .requestPlain
        case let .postPlainText(_, _, body): .requestData(Data(body.utf8))
        }
    }

    var validationType: ValidationType { .successCodes }

    var sampleData: Data { Data() }
}
