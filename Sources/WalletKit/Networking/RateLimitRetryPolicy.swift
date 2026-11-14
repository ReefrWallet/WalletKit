import Alamofire
import Foundation

/// Reactive half of the rate-limit handling: retries real HTTP 429/503
/// responses, honoring `Retry-After` (numeric seconds or an HTTP-date) or
/// falling back to jittered exponential backoff. Proactive pacing (the
/// other half) happens in `adapt`, which acquires a slot from `gate` in the
/// request's ``RequestLane`` before every attempt — including retries, since
/// Alamofire re-runs `adapt` for each one but never re-enters the call site
/// that constructed this policy.
///
/// Also an `EventMonitor`, to tie a queued gate waiter to its request's
/// cancellation and to count successful responses toward the gate's recovery.
///
/// Not publicly constructible — obtained via
/// ``RateGateRegistry/makeRetryPolicy(for:provider:)``.
public final class RateLimitRetryPolicy: RequestInterceptor, EventMonitor, @unchecked Sendable {
    /// Request property carrying the issuing task's lane. Set before Alamofire
    /// sees the request, because task-locals aren't readable inside `adapt`.
    static let laneKey = "xyz.reefr.walletkit.request-lane"

    /// Per-request state. A request's cancel can arrive before, during or
    /// after its adapter runs (Alamofire skips the adapter for a cancelled
    /// request, and delivers monitor events asynchronously), so everything
    /// lives in one lock-protected entry.
    private struct Entry {
        var task: Task<Void, Never>?
        var notBefore: ContinuousClock.Instant?
        var isCancelled = false
        var touched = ContinuousClock.now
    }

    let gate: RateGate<ContinuousClock>?
    let maxRetryCount: Int
    let countsHTTPSuccess: Bool
    /// Statuses worth replaying. A 503 can follow an accepted request, so a non-idempotent call drops it.
    let retriedStatuses: Set<Int>
    public let queue = DispatchQueue(label: "xyz.reefr.walletkit.rate-limit-monitor")
    private let jitterSource: @Sendable () -> Double
    private let maxRetryAfter: Duration
    private let lock = NSLock()
    private var entries: [UUID: Entry] = [:]

    private static let tombstoneLifetime = Duration.seconds(60)

    init(
        gate: RateGate<ContinuousClock>?,
        maxRetryCount: Int,
        countsHTTPSuccess: Bool = true,
        retriedStatuses: Set<Int> = [429, 503],
        maxRetryAfter: Duration = .seconds(60),
        jitterSource: @escaping @Sendable () -> Double = { Double.random(in: 0.85 ... 1.15) }
    ) {
        self.countsHTTPSuccess = countsHTTPSuccess
        self.retriedStatuses = retriedStatuses
        self.gate = gate
        self.maxRetryAfter = maxRetryAfter
        self.maxRetryCount = maxRetryCount
        self.jitterSource = jitterSource
    }

    /// Number of requests with live state, for tests.
    var trackedRequestCount: Int {
        lock.withLock { entries.count }
    }

    /// Whether any request still has an acquire task or retry deadline, for tests.
    var hasPendingState: Bool {
        lock.withLock { entries.values.contains { $0.task != nil || $0.notBefore != nil } }
    }

    public func adapt(
        _ urlRequest: URLRequest,
        for session: Session,
        completion: @escaping @Sendable (Result<URLRequest, Error>) -> Void
    ) {
        completion(.success(urlRequest))
    }

    public func adapt(
        _ urlRequest: URLRequest,
        using state: RequestAdapterState,
        completion: @escaping @Sendable (Result<URLRequest, Error>) -> Void
    ) {
        let id = state.requestID
        let lane = (URLProtocol.property(forKey: Self.laneKey, in: urlRequest) as? String)
            .flatMap(RequestLane.init(rawValue:)) ?? .interactive

        let isCancelled = lock.withLock { () -> Bool in
            prune()
            return entries[id]?.isCancelled ?? false
        }

        guard !isCancelled else {
            completion(.failure(CancellationError()))
            return
        }

        guard gate != nil || lock.withLock({ entries[id]?.notBefore != nil }) else {
            completion(.success(urlRequest))
            return
        }

        // Bridges the async gate into Alamofire's completion-based adapter.
        // `requestDidCancel` cancels this task, which drops the gate waiter.
        let task = Task { [gate] in
            do {
                if let notBefore = self.lock.withLock({ self.entries[id]?.notBefore }) {
                    try await Task.sleep(until: notBefore, clock: .continuous)
                }

                try await gate?.acquire(lane: lane)
                self.finishAdapt(id)
                completion(.success(urlRequest))
            } catch {
                self.finishAdapt(id)
                completion(.failure(error))
            }
        }

        lock.withLock {
            var entry = entries[id] ?? Entry()

            if entry.isCancelled {
                task.cancel()
            } else {
                entry.task = task
                entry.touched = .now
                entries[id] = entry
            }
        }
    }

    public func retry(
        _ request: Request,
        for session: Session,
        dueTo error: Error,
        completion: @escaping @Sendable (RetryResult) -> Void
    ) {
        guard
            let response = request.task?.response as? HTTPURLResponse,
            retriedStatuses.contains(response.statusCode)
        else {
            completion(.doNotRetryWithError(error))
            return
        }

        let fallbackDelay = Self.backoffSeconds(attempt: request.retryCount, jitter: jitterSource())
        let delaySeconds = min(
            Self.retryAfterSeconds(response: response) ?? fallbackDelay,
            maxRetryAfter.timeIntervalValue
        )

        // A 429 (explicit quota-exceeded) reports to the shared gate even when
        // this request can't be replayed, so other callers slow down too. A 503
        // is a general availability signal that may be unrelated to this
        // client's request volume.
        let report: @Sendable () async -> Void = { [gate] in
            if response.statusCode == 429 {
                await gate?.penalize(by: .seconds(delaySeconds))
            }
        }

        guard request.retryCount < maxRetryCount else {
            Task {
                await report()
                completion(.doNotRetryWithError(error))
            }

            return
        }

        // Alamofire's `.retryWithDelay` can leave a cancelled caller hanging,
        // so the delay is enforced by the next `adapt` instead.
        let isAllowed = lock.withLock { () -> Bool in
            var entry = entries[request.id] ?? Entry()

            guard !entry.isCancelled, !request.isCancelled else {
                return false
            }

            entry.notBefore = .now.advanced(by: .seconds(delaySeconds))
            entry.touched = .now
            entries[request.id] = entry
            return true
        }

        Task {
            await report()
            completion(isAllowed ? .retry : .doNotRetryWithError(error))
        }
    }

    // MARK: - EventMonitor

    public func requestDidCancel(_ request: Request) {
        lock.withLock {
            prune()
            var entry = entries[request.id] ?? Entry()
            entry.task?.cancel()
            entry.task = nil
            entry.notBefore = nil
            entry.isCancelled = true
            entry.touched = .now
            entries[request.id] = entry
        }
    }

    public func requestDidFinish(_ request: Request) {
        let task = lock.withLock { entries.removeValue(forKey: request.id)?.task }
        task?.cancel()
    }

    public func request(_ request: Request, didCompleteTask task: URLSessionTask, with error: AFError?) {
        guard
            countsHTTPSuccess, error == nil,
            let status = (task.response as? HTTPURLResponse)?.statusCode,
            (200 ..< 300).contains(status)
        else {
            return
        }

        Task { [gate] in
            await gate?.recordSuccess()
        }
    }

    private func finishAdapt(_ id: UUID) {
        lock.withLock {
            guard var entry = entries[id] else {
                return
            }

            entry.task = nil
            entry.notBefore = nil
            entries[id] = entry.isCancelled ? entry : nil
        }
    }

    /// Drops cancel tombstones whose request never reached `finish`. Call under `lock`.
    private func prune() {
        let now = ContinuousClock.now
        entries = entries.filter { _, entry in
            !(entry.isCancelled && entry.touched.duration(to: now) > Self.tombstoneLifetime)
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
