//
//  JSONRPCClient.swift
//  WalletKit
//
//  Created by Andrey Yurkevich on 17/08/2026.
//  Copyright © 2026 Reefr Wallet. All rights reserved.
//

import Foundation

/// A JSON-RPC 2.0 transport over HTTPS POST — the `{jsonrpc, id, method,
/// params}` → `{result}`/`{error}` envelope Ethereum's execution-apis use.
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
        var request = URLRequest(url: endpoint)

        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(Envelope(method: method, params: params))

        let data: Data
        let response: URLResponse

        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw BlockchainClientError.transportError(reason: error.localizedDescription)
        }

        guard let httpResponse = response as? HTTPURLResponse, (200..<300).contains(httpResponse.statusCode) else {
            let status = (response as? HTTPURLResponse)?.statusCode ?? -1
            throw BlockchainClientError.invalidResponse(reason: "unexpected HTTP status \(status)")
        }

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
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        var body = Data("{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":".utf8)
        body.append(try JSONEncoder().encode(method))
        body.append(Data(",\"params\":".utf8))
        body.append(params)
        body.append(Data("}".utf8))
        request.httpBody = body

        let data: Data
        let response: URLResponse

        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw BlockchainClientError.transportError(reason: error.localizedDescription)
        }

        guard let httpResponse = response as? HTTPURLResponse, (200..<300).contains(httpResponse.statusCode) else {
            let status = (response as? HTTPURLResponse)?.statusCode ?? -1
            throw BlockchainClientError.invalidResponse(reason: "unexpected HTTP status \(status)")
        }

        guard let envelope = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]) as? [String: Any] else {
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
        guard !params.isEmpty else { return [] }

        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(
            params.enumerated().map { BatchEnvelope(id: $0.offset + 1, method: method, params: $0.element) }
        )

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw BlockchainClientError.transportError(reason: error.localizedDescription)
        }

        guard let httpResponse = response as? HTTPURLResponse, (200..<300).contains(httpResponse.statusCode) else {
            let status = (response as? HTTPURLResponse)?.statusCode ?? -1
            throw BlockchainClientError.invalidResponse(reason: "unexpected HTTP status \(status)")
        }

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
}
