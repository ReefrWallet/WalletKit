//
//  JSONRPCClient.swift
//  WalletKit
//
//  Created by Andrey Yurkevich on 17/08/2026.
//  Copyright © 2026 Reefr Wallet. All rights reserved.
//

import Alamofire
import Foundation
import Moya

/// A JSON-RPC 2.0 transport over HTTPS POST — the `{jsonrpc, id, method,
/// params}` → `{result}`/`{error}` envelope Ethereum's execution-apis use.
///
/// Rate-limit handling (retrying 429/503 with backoff, proactive pacing
/// where a confirmed rate is configured) comes from ``RateGateRegistry``,
/// shared process-wide and looked up by this client's own endpoint — a
/// public default RPC and a user's `rpcURLOverride` are different origins
/// and don't throttle each other.
struct JSONRPCClient {
    let endpoint: URL
    var session: URLSession = .shared

    private struct Envelope<Params: Encodable>: Encodable {
        let jsonrpc = "2.0"
        let id = 1
        let method: String
        let params: Params
    }

    private struct BatchEnvelope<Params: Encodable>: Encodable {
        let jsonrpc = "2.0"
        let id: Int
        let method: String
        let params: Params
    }

    private struct ErrorPayload: Decodable {
        let code: Int
        let message: String
    }

    private struct ResponseEnvelope<Result: Decodable>: Decodable {
        let result: Result?
        let error: ErrorPayload?
    }

    private struct BatchResponseEnvelope<Result: Decodable>: Decodable {
        let id: Int
        let result: Result?
        let error: ErrorPayload?
    }

    /// Calls `method` with `params`, decoding the JSON-RPC `result` as
    /// `Result`.
    ///
    /// - Throws: ``BlockchainClientError`` for a transport failure, a
    ///   non-2xx HTTP status, a JSON-RPC `error` response, or a `result`
    ///   that doesn't decode as `Result`.
    func call<Params: Encodable, Result: Decodable>(
        method: String,
        params: Params
    ) async throws -> Result {
        let body = try JSONEncoder().encode(Envelope(method: method, params: params))
        let data = try await send(body)

        let envelope: ResponseEnvelope<Result>

        do {
            envelope = try JSONDecoder().decode(ResponseEnvelope<Result>.self, from: data)
        } catch {
            throw BlockchainClientError.decodingFailed(reason: error.localizedDescription)
        }

        if let error = envelope.error {
            throw BlockchainClientError.rpcError(code: error.code, message: error.message)
        }

        guard let result = envelope.result else {
            throw BlockchainClientError.invalidResponse(reason: "response had neither result nor error")
        }

        return result
    }

    /// Calls `method` with an already-JSON-encoded `params` value,
    /// returning the raw `result` JSON verbatim rather than decoding it
    /// into a fixed `Decodable` type — the passthrough surface for
    /// arbitrary RPC calls with no compile-time result type (a dapp
    /// bridge's read-only allowlist).
    ///
    /// - Throws: ``BlockchainClientError`` for a transport failure, a
    ///   non-2xx HTTP status, or a JSON-RPC `error` response.
    func call(method: String, params: Data) async throws -> Data {
        var body = Data("{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":".utf8)
        body.append(try JSONEncoder().encode(method))
        body.append(Data(",\"params\":".utf8))
        body.append(params)
        body.append(Data("}".utf8))

        let data = try await send(body)

        guard let envelope = try? JSONSerialization.jsonObject(
            with: data,
            options: [.fragmentsAllowed]
        ) as? [String: Any] else {
            throw BlockchainClientError.decodingFailed(reason: "response was not a JSON object")
        }

        if let error = envelope["error"] as? [String: Any] {
            throw BlockchainClientError.rpcError(
                code: error["code"] as? Int ?? 0,
                message: error["message"] as? String ?? "unknown error"
            )
        }

        guard let result = envelope["result"] else {
            throw BlockchainClientError.invalidResponse(reason: "response had neither result nor error")
        }

        return try JSONSerialization.data(withJSONObject: result, options: [.fragmentsAllowed])
    }

    /// Calls the same JSON-RPC method with multiple parameter sets in one HTTP
    /// request. Individual RPC errors are represented by `nil` at their input
    /// index so callers can preserve partial-success semantics.
    func callBatch<Params: Encodable, Result: Decodable>(
        method: String,
        params: [Params]
    ) async throws -> [Result?] {
        guard !params.isEmpty else {
            return []
        }

        let body = try JSONEncoder().encode(
            params.enumerated().map { BatchEnvelope(id: $0.offset + 1, method: method, params: $0.element) }
        )

        let data = try await send(body)

        let envelopes: [BatchResponseEnvelope<Result>]
        do {
            envelopes = try JSONDecoder().decode([BatchResponseEnvelope<Result>].self, from: data)
        } catch {
            throw BlockchainClientError.decodingFailed(reason: error.localizedDescription)
        }

        var results: [Result?] = Array(repeating: nil, count: params.count)
        for envelope in envelopes where envelope.id > 0 && envelope.id <= params.count {
            results[envelope.id - 1] = envelope.error == nil ? envelope.result : nil
        }

        return results
    }

    // MARK: - Private helpers

    /// POSTs `body`, retrying rate-limited (429) and unavailable (503)
    /// responses with backoff via ``RateGateRegistry``'s shared interceptor
    /// for this endpoint.
    private func send(_ body: Data) async throws -> Data {
        let policy = RateGateRegistry.shared.makeRetryPolicy(for: origin, provider: .jsonRPC)
        let afSession = Session(configuration: session.configuration, interceptor: policy)
        let provider = MoyaProvider<JSONRPCTarget>(session: afSession)

        do {
            return try await provider.requestData(.post(endpoint: endpoint, body: body))
        } catch let error as MoyaError {
            throw Self.mapError(error)
        }
    }

    /// `origin`: scheme + host + explicit port only (not a default one) —
    /// matches ``RateGateRegistry``'s keying, so a custom `rpcURLOverride`
    /// on a different port is treated as a distinct endpoint.
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
            return .invalidResponse(reason: "unexpected HTTP status \(response.statusCode)")
        case let .underlying(underlying, response):
            guard let response else {
                return .transportError(reason: underlying.localizedDescription)
            }

            return .invalidResponse(reason: "unexpected HTTP status \(response.statusCode)")
        default:
            return .transportError(reason: error.localizedDescription)
        }
    }
}

private enum JSONRPCTarget: TargetType {
    case post(endpoint: URL, body: Data)

    var baseURL: URL {
        switch self {
        case let .post(endpoint, _): endpoint
        }
    }

    var path: String { "" }

    var method: Moya.Method { .post }

    var headers: [String: String]? {
        ["Content-Type": "application/json"]
    }

    var task: Moya.Task {
        switch self {
        case let .post(_, body): .requestData(body)
        }
    }

    var validationType: ValidationType { .successCodes }

    var sampleData: Data { Data() }
}
