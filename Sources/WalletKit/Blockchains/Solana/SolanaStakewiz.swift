//
//  SolanaStakewiz.swift
//  WalletKit
//
//  Created by Andrey Yurkevich on 06/11/2026.
//  Copyright © 2026 Reefr Wallet. All rights reserved.
//

import Alamofire
import Foundation
import Moya

/// Stakewiz's public validator list: names, logos, commission and APY.
enum SolanaStakewiz {
    /// The public API's base URL.
    static let endpoint = URL(string: "https://api.stakewiz.com")!

    struct Validator: Decodable {
        // swiftlint:disable identifier_name
        let commission: Int?
        let delinquent: Bool?
        let image: String?
        let name: String?
        let total_apy: Double?
        let vote_identity: String
        let wiz_score: Double?
        // swiftlint:enable identifier_name

        var validator: SolanaValidator {
            SolanaValidator(
                // Through text: a `Double` would carry its binary noise into the rate.
                apy: total_apy.flatMap {
                    Decimal(string: String(format: "%.2f", $0), locale: Locale(identifier: "en_US_POSIX"))
                },
                commission: commission,
                imageURL: image.flatMap(URL.init(string:)),
                isDelinquent: delinquent ?? false,
                name: name.flatMap { $0.isEmpty ? nil : $0 },
                voteAddress: vote_identity
            )
        }
    }

    static func validators(endpoint: URL, session: URLSession) async throws -> Data {
        let origin = endpoint.host.map { "\(endpoint.scheme ?? "https")://\($0)" } ?? endpoint.absoluteString
        let policy = RateGateRegistry.shared.makeRetryPolicy(for: origin, provider: .stakewiz)
        let provider = MoyaProvider<API>(session: Session(configuration: session.configuration, interceptor: policy))

        do {
            return try await provider.requestData(API(endpoint: endpoint))
        } catch let error as MoyaError {
            throw BlockchainClientError.transportError(reason: error.localizedDescription)
        }
    }

    private struct API: TargetType {
        let endpoint: URL

        var baseURL: URL { endpoint }
        var headers: [String: String]? { nil }
        var method: Moya.Method { .get }
        var path: String { "validators" }
        var task: Moya.Task { .requestPlain }
    }
}
