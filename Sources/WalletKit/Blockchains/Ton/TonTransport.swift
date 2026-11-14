//
//  TonTransport.swift
//  WalletKit
//
//  Copyright © 2026 Reefr Wallet. All rights reserved.
//

import Alamofire
import Foundation
import Moya

/// The HTTP layer under ``TonClient``; replaceable in tests.
protocol TonTransport: Sendable {
    func get(_ url: URL) async throws -> Data
    func post(_ url: URL, body: Data) async throws -> Data
    /// A POST that must not be replayed after an ambiguous failure: only a rate-limit refusal (429, the request
    /// was not processed) is retried; a 503 is left to the caller's reconciliation.
    func submit(_ url: URL, body: Data) async throws -> Data
}

extension TonTransport {
    func submit(_ url: URL, body: Data) async throws -> Data {
        try await post(url, body: body)
    }
}

/// toncenter over `URLSession`, through the shared rate gate.
struct TonCenterTransport: TonTransport {
    static let callTimeout: TimeInterval = 10

    let apiKey: String?
    let session: URLSession

    func get(_ url: URL) async throws -> Data {
        try await request(.get(url: url, headers: headers))
    }

    func post(_ url: URL, body: Data) async throws -> Data {
        try await request(.post(url: url, headers: headers, body: body))
    }

    func submit(_ url: URL, body: Data) async throws -> Data {
        try await request(.post(url: url, headers: headers, body: body), retriedStatuses: [429])
    }

    private var headers: [String: String] {
        var headers = ["Accept": "application/json", "Content-Type": "application/json"]

        if let apiKey {
            headers["X-API-Key"] = apiKey
        }

        return headers
    }

    private func request(_ target: TonCenterAPI, retriedStatuses: Set<Int> = [429, 503]) async throws -> Data {
        let configuration = session.configuration
        configuration.timeoutIntervalForRequest = Self.callTimeout
        let url = target.baseURL
        var components = URLComponents()
        components.scheme = url.scheme
        components.host = url.host
        components.port = url.port
        let provider: MoyaProvider<TonCenterAPI> = RateGateRegistry.shared.makeProvider(
            origin: components.string ?? url.absoluteString,
            provider: .toncenter,
            configuration: configuration,
            retriedStatuses: retriedStatuses
        )

        do {
            return try await provider.requestData(target)
        } catch let error as MoyaError {
            throw Self.map(error)
        }
    }

    private static func map(_ error: MoyaError) -> any Swift.Error {
        let response: Moya.Response? = switch error {
        case let .statusCode(response): response
        case let .underlying(_, response): response
        default: nil
        }

        guard let response else {
            return BlockchainClientError.transportError(reason: error.localizedDescription)
        }

        let message = String(data: response.data, encoding: .utf8) ?? ""

        if response.statusCode == 429 {
            return BlockchainClientError.quotaExceeded(code: 429, message: message, retryAfter: nil)
        }

        return BlockchainClientError.rpcError(code: response.statusCode, message: message)
    }
}

enum TonCenterAPI: TargetType {
    case get(url: URL, headers: [String: String])
    case post(url: URL, headers: [String: String], body: Data)

    var baseURL: URL {
        switch self {
        case let .get(url, _), let .post(url, _, _): url
        }
    }

    var path: String { "" }

    var method: Moya.Method {
        switch self {
        case .get: .get
        case .post: .post
        }
    }

    var headers: [String: String]? {
        switch self {
        case let .get(_, headers), let .post(_, headers, _): headers
        }
    }

    var task: Moya.Task {
        switch self {
        case .get: .requestPlain
        case let .post(_, _, body): .requestData(body)
        }
    }

    var validationType: ValidationType { .successCodes }
}
