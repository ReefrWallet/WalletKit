import Alamofire
import Foundation
import Moya

/// Recognizes an origin's "you are over quota" replies. A code alone is never
/// enough: Infura reuses `-32005` for `eth_getLogs` result caps and query
/// timeouts, which say nothing about the request rate.
enum QuotaSignal {
    /// Codes providers use for quota errors; counted only with quota metadata (429 needs none).
    private static let quotaCodes: Set<Int> = [429, -32005, -32007, -32008, -32011]

    /// Lowercased message fragments that mark a quota error.
    private static let quotaPhrases = [
        "compute units per second", // Alchemy: code 429 "exceeded its compute units per second capacity"
        "daily request count exceeded", // Infura: -32005 (docs.infura.io, avoid-rate-limiting)
        "rate limit", // generic; Etherscan, Blockscout, Blockfrost
        "rate-limit",
        "request limit", // QuickNode: -32007 per-second, -32008 per-minute, -32011 method limit
        "request rate", // Infura: -32005 "project ID request rate exceeded" / "request rate limited"
        "too many requests"
    ]

    /// Fragments of `-32005`/`-32602` replies that are about the query, not the rate.
    private static let queryPhrases = [
        "block range",
        "log response size",
        "query returned more than", // Infura eth_getLogs result cap
        "query timeout"
    ]

    /// Longest cooldown a provider may ask for, as for `Retry-After` in ``RateLimitRetryPolicy``.
    /// Clamped before conversion: a huge finite `Double` would overflow `Duration`.
    static let maxRetryAfterSeconds = 60.0

    /// Provider metadata keys that only appear on quota replies.
    private static let quotaMetadataKeys: Set<String> = ["allowed_rps", "backoff_seconds", "current_rps", "retry_after"]

    /// The cooldown the reply asks for, if any, when it is a quota signal; `nil` when it isn't.
    static func detect(code: Int, message: String, data: [String: Any]?) -> Classification? {
        let lowered = message.lowercased()

        if queryPhrases.contains(where: lowered.contains) {
            return nil
        }

        let retryAfter = data.flatMap(retryAfter)

        // 429 is HTTP's own quota status; unlike `-32005` it has no other meaning.
        if code == 429 || quotaPhrases.contains(where: lowered.contains) {
            return Classification(retryAfter: retryAfter)
        }

        guard quotaCodes.contains(code), let data, !quotaMetadataKeys.isDisjoint(with: data.keys) else {
            return nil
        }

        return Classification(retryAfter: retryAfter)
    }

    struct Classification: Equatable {
        let retryAfter: Duration?
    }

    private static func retryAfter(_ data: [String: Any]) -> Duration? {
        for key in ["backoff_seconds", "retry_after"] {
            if let seconds = (data[key] as? NSNumber)?.doubleValue, seconds.isFinite, seconds >= 0 {
                return .seconds(min(seconds, maxRetryAfterSeconds))
            }
        }

        return nil
    }
}

public extension Error {
    /// Whether this failure means the origin is rate-limiting this app: an
    /// HTTP 429, or a reply a transport classified as quota-exceeded.
    var isQuotaExceeded: Bool {
        switch self as any Error {
        case BlockchainClientError.quotaExceeded:
            true

        case let BlockchainClientError.invalidResponse(reason):
            reason.contains("HTTP status 429") || reason.hasPrefix("HTTP 429")

        case let BlockchainClientError.rpcError(code, message):
            QuotaSignal.detect(code: code, message: message, data: nil) != nil

        case let error as AFError:
            error.responseCode == 429

        case let MoyaError.underlying(error, response):
            response?.statusCode == 429 || error.isQuotaExceeded

        case let error as MoyaError:
            error.response?.statusCode == 429

        default:
            false
        }
    }
}
