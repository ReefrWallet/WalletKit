import Foundation

/// Registry and backoff used by ``QuotaRetry``; tests substitute their own.
struct QuotaRetryContext: Sendable {
    var registry: RateGateRegistry = .shared
    var backoff: @Sendable (Int) -> Duration = { .seconds(RateLimitRetryPolicy.backoffSeconds(attempt: $0)) }
}

/// The gated-call loop of transports with no Moya pipeline (Sui gRPC, Electrum).
enum QuotaRetry {
    /// Runs `call` once per gate slot, in the calling task's ``RequestLane``. A
    /// success is reported to the gate. A `BlockchainClientError.quotaExceeded`
    /// slows the origin's gate and, while `retries` remain, replays `call`;
    /// any other error (including cancellation of a queued acquisition) passes through.
    static func run<Response>(
        _ context: QuotaRetryContext,
        origin: String,
        provider: ProviderKind,
        retries: Int,
        _ call: () async throws -> Response
    ) async throws -> Response {
        for attempt in 0... {
            try await context.registry.acquire(origin: origin, provider: provider)

            do {
                let response = try await call()
                await context.registry.reportSuccess(origin: origin, provider: provider)
                return response
            } catch let BlockchainClientError.quotaExceeded(code, message, retryAfter) {
                let delay = retryAfter ?? context.backoff(attempt)
                await context.registry.reportQuotaExceeded(origin: origin, provider: provider, retryAfter: delay)

                guard attempt < retries else {
                    throw BlockchainClientError.quotaExceeded(code: code, message: message, retryAfter: delay)
                }
            }
        }

        throw CancellationError()
    }
}
