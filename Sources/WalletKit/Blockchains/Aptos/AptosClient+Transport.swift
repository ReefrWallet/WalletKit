//
//  AptosClient+Transport.swift
//  WalletKit
//
//  Copyright © 2026 Reefr Wallet. All rights reserved.
//

import Alamofire
import Foundation
import Moya

// MARK: - Transport

enum AptosHTTPError: Swift.Error {
    case notFound
    case rejected(status: Int, errorCode: String?, message: String)
}

extension AptosClient {
    static let signedTransactionContentType = "application/x.aptos.signed_transaction+bcs"

    /// Node error codes for a duplicate of an already-accepted transaction.
    static let alreadySubmittedCodes: Set<String> = [
        "invalid_transaction_update", "sequence_number_too_old", "transaction_already_in_mempool"
    ]

    var headers: [String: String] {
        var headers = ["Accept": "application/json"]
        if let apiKey {
            headers["Authorization"] = "Bearer \(apiKey)"
        }

        return headers
    }

    func url(_ path: String) -> URL {
        path.isEmpty ? endpoint : endpoint.appending(path: path)
    }

    func get<Response: Decodable>(_ path: String) async throws -> Response {
        let data = try await requestData(.get(url: url(path), headers: headers))

        do {
            return try JSONDecoder().decode(Response.self, from: data)
        } catch {
            throw BlockchainClientError.decodingFailed(reason: "Aptos \(path): \(error)")
        }
    }

    func requestData(_ target: AptosAPI) async throws -> Data {
        let policy = RateGateRegistry.shared.makeRetryPolicy(for: origin, provider: .aptosLabs)
        let configuration = session.configuration
        configuration.timeoutIntervalForRequest = Self.callTimeout
        let provider = MoyaProvider<AptosAPI>(session: Session(configuration: configuration, interceptor: policy))

        do {
            return try await provider.requestData(target)
        } catch let error as MoyaError {
            throw Self.mapError(error)
        }
    }

    /// Scheme + host + explicit port, matching ``RateGateRegistry``'s keying.
    private var origin: String {
        var components = URLComponents()
        components.scheme = endpoint.scheme
        components.host = endpoint.host
        components.port = endpoint.port
        return components.string ?? endpoint.absoluteString
    }

    private static func mapError(_ error: MoyaError) -> any Swift.Error {
        let response: Moya.Response? = switch error {
        case let .statusCode(response): response
        case let .underlying(_, response): response
        default: nil
        }

        guard let response else {
            return BlockchainClientError.transportError(reason: error.localizedDescription)
        }

        if response.statusCode == 404 {
            return AptosHTTPError.notFound
        }

        let body = try? JSONDecoder().decode(NodeErrorResponse.self, from: response.data)
        return AptosHTTPError.rejected(
            status: response.statusCode,
            errorCode: body?.errorCode,
            message: body?.message ?? String(data: response.data, encoding: .utf8) ?? ""
        )
    }
}

extension AptosHTTPError: LocalizedError {
    var errorDescription: String? {
        switch self {
        case .notFound: "Not found on the Aptos node."
        case let .rejected(status, _, message): "Aptos node rejected the request (HTTP \(status)): \(message)"
        }
    }
}

enum AptosAPI: TargetType {
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

    var sampleData: Data { Data() }
}

private struct NodeErrorResponse: Decodable {
    let errorCode: String?
    let message: String?

    enum CodingKeys: String, CodingKey {
        case errorCode = "error_code"
        case message
    }
}

// MARK: - Decoding

/// An indexer `numeric`/`bigint`: a JSON number or a decimal string.
/// Kept as text so values beyond `UInt64` survive.
struct AptosIndexerNumber: Decodable, Sendable, CustomStringConvertible {
    let description: String

    init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()

        if let string = try? container.decode(String.self) {
            description = string
        } else if let integer = try? container.decode(Int64.self) {
            description = String(integer)
        } else if let unsigned = try? container.decode(UInt64.self) {
            description = String(unsigned)
        } else {
            let decimal = try container.decode(Decimal.self)
            description = NSDecimalNumber(decimal: decimal).stringValue
        }
    }
}

extension KeyedDecodingContainer {
    /// A `u64` sent as a decimal string (Aptos, Blockfrost) or a JSON number.
    func decodeNumericString(forKey key: Key) throws -> UInt64 {
        guard let value = try decodeNumericStringIfPresent(forKey: key) else {
            throw DecodingError.keyNotFound(key, .init(codingPath: codingPath, debugDescription: "missing \(key)"))
        }

        return value
    }

    func decodeNumericStringIfPresent(forKey key: Key) throws -> UInt64? {
        if let string = try? decodeIfPresent(String.self, forKey: key) {
            guard let value = UInt64(string) else {
                throw DecodingError.dataCorruptedError(forKey: key, in: self, debugDescription: "not a u64: \(string)")
            }

            return value
        }

        return try decodeIfPresent(UInt64.self, forKey: key)
    }

    func decodeNumericUInt32(forKey key: Key) throws -> UInt32 {
        let value = try decodeNumericString(forKey: key)
        guard let narrowed = UInt32(exactly: value) else {
            throw DecodingError.dataCorruptedError(forKey: key, in: self, debugDescription: "not a u32: \(value)")
        }

        return narrowed
    }
}
