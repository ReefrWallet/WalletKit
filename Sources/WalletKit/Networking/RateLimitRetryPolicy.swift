import Alamofire
import Foundation

/// Reactive half of the rate-limit handling: retries real HTTP 429/503
/// responses, honoring `Retry-After` (numeric seconds or an HTTP-date) or
/// falling back to jittered exponential backoff. Proactive pacing (the
/// other half) happens in `adapt`, which acquires a slot from `gate` before
/// every attempt — including retries, since Alamofire re-runs `adapt` for
/// each one but never re-enters the call site that constructed this policy.
///
/// Not publicly constructible — obtained via
/// ``RateGateRegistry/makeRetryPolicy(for:provider:)``.
public final class RateLimitRetryPolicy: RequestInterceptor, @unchecked Sendable {
    let gate: RateGate<ContinuousClock>?
    let maxRetryCount: Int
    private let jitterSource: @Sendable () -> Double
    private let maxRetryAfter: Duration

    init(
        gate: RateGate<ContinuousClock>?,
        maxRetryCount: Int,
        maxRetryAfter: Duration = .seconds(60),
        jitterSource: @escaping @Sendable () -> Double = { Double.random(in: 0.85 ... 1.15) }
    ) {
        self.gate = gate
        self.maxRetryAfter = maxRetryAfter
        self.maxRetryCount = maxRetryCount
        self.jitterSource = jitterSource
    }

    public func adapt(
        _ urlRequest: URLRequest,
        for session: Session,
        completion: @escaping (Result<URLRequest, Error>) -> Void
    ) {
        guard let gate else {
            completion(.success(urlRequest))
            return
        }

        // Bridges the async gate into Alamofire's completion-based adapter.
        // Best-effort cancellation: `RateGate.acquire()` already resumes a
        // cancelled waiter with `CancellationError` (see `RateGate`), so a
        // request cancelled while queued doesn't occupy a slot forever —
        // Alamofire's own `RequestAdapter` protocol has no direct "this
        // request was cancelled" callback to tie this `Task` to more
        // tightly than that.
        Task {
            do {
                try await gate.acquire()
                completion(.success(urlRequest))
            } catch {
                completion(.failure(error))
            }
        }
    }

    public func retry(
        _ request: Request,
        for session: Session,
        dueTo error: Error,
        completion: @escaping (RetryResult) -> Void
    ) {
        guard
            let response = request.task?.response as? HTTPURLResponse,
            [429, 503].contains(response.statusCode),
            request.retryCount < maxRetryCount
        else {
            completion(.doNotRetryWithError(error))
            return
        }

        let fallbackDelay = Self.backoffSeconds(attempt: request.retryCount, jitter: jitterSource())
        let delaySeconds = min(
            Self.retryAfterSeconds(response: response) ?? fallbackDelay,
            maxRetryAfter.timeIntervalValue
        )

        // Only a 429 (explicit quota-exceeded) depresses the shared gate for
        // every other caller. A 503 is a general availability signal that
        // may be unrelated to this client's request volume.
        guard response.statusCode == 429, let gate else {
            completion(.retryWithDelay(delaySeconds))
            return
        }

        Task {
            await gate.penalize(by: .seconds(delaySeconds))
            completion(.retryWithDelay(delaySeconds))
        }
    }

    /// Shared with `EtherscanTransactionHistorySource`'s in-band
    /// rate-limit detection, which can't go through `retry` above since
    /// Etherscan signals its limit inside an HTTP 200 body.
    public static func backoffSeconds(
        attempt: Int,
        baseDelay: Double = 1,
        jitter: Double = Double.random(in: 0.85 ... 1.15)
    ) -> Double {
        baseDelay * pow(2, Double(attempt)) * jitter
    }

    static func retryAfterSeconds(response: HTTPURLResponse) -> Double? {
        guard let header = response.value(forHTTPHeaderField: "Retry-After") else {
            return nil
        }

        if let seconds = Double(header) {
            return max(0, seconds)
        }

        if let date = httpDateFormatter.date(from: header) {
            return max(0, date.timeIntervalSinceNow)
        }

        return nil
    }

    private static let httpDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "GMT")
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
        return formatter
    }()
}

extension Duration {
    var timeIntervalValue: TimeInterval {
        let components = components
        return Double(components.seconds) + Double(components.attoseconds) / 1e18
    }
}
