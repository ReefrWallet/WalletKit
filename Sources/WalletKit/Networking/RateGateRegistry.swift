import Alamofire
import Foundation
import Moya

/// Identifies which 3rd-party API a client is talking to, independent of
/// the specific origin (host/port) — needed because some providers (Cardano
/// via Blockfrost, Tron via TronGrid, and arbitrary JSON-RPC endpoints) can
/// be pointed at a custom/self-hosted origin via an account's RPC override,
/// and an unlisted origin must still resolve to *this* provider's default,
/// never a different provider's.
public enum ProviderKind: Hashable, Sendable {
    case aptosLabs
    case blockfrost
    case blockscout
    case electrum
    case esplora
    case etherscan
    case jsonRPC
    case stakewiz
    case suiGRPC
    case toncenter
    case tronGrid
}

/// `maxCallsPerSecond == nil` means an adaptive gate: no pacing until the
/// origin signals quota, then a pace learned from that signal (see
/// `RateGate`) — the deliberate default for providers (or origins) whose
/// real rate limit hasn't been confirmed. Assigning a guessed proactive rate
/// has a real cost (throttling a local node or a generous provider as if it
/// were the strictest one), so a fixed rate is only ever added once it's
/// known, not assumed.
public struct RateLimitPolicy: Sendable {
    public let maxCallsPerSecond: Double?
    public let maxRetryCount: Int

    public init(maxCallsPerSecond: Double?, maxRetryCount: Int) {
        self.maxCallsPerSecond = maxCallsPerSecond
        self.maxRetryCount = maxRetryCount
    }

    static let reactiveOnly = RateLimitPolicy(maxCallsPerSecond: nil, maxRetryCount: 3)

    /// A known, confirmed origin's policy override — takes precedence over
    /// its provider kind's default (see `providerDefaults` below).
    struct ExactEntry {
        let origin: String
        let provider: ProviderKind
        let policy: RateLimitPolicy
    }

    /// Known, confirmed origins get a proactive rate; everything else
    /// (including these same providers at a different/custom origin) falls
    /// back to `providerDefaults` below.
    static let exactPolicies: [ExactEntry] = [
        ExactEntry(
            origin: "https://api.etherscan.io",
            provider: .etherscan,
            policy: RateLimitPolicy(maxCallsPerSecond: 2.5, maxRetryCount: 3)
        ),
        ExactEntry(
            origin: "https://eth.blockscout.com",
            provider: .blockscout,
            policy: RateLimitPolicy(maxCallsPerSecond: 2, maxRetryCount: 3)
        ),
        ExactEntry(
            origin: "https://arbitrum.blockscout.com",
            provider: .blockscout,
            policy: RateLimitPolicy(maxCallsPerSecond: 2, maxRetryCount: 3)
        ),
        ExactEntry(
            origin: "https://arbitrum-sepolia.blockscout.com",
            provider: .blockscout,
            policy: RateLimitPolicy(maxCallsPerSecond: 2, maxRetryCount: 3)
        ),
        ExactEntry(
            origin: "https://eth-sepolia.blockscout.com",
            provider: .blockscout,
            policy: RateLimitPolicy(maxCallsPerSecond: 2, maxRetryCount: 3)
        ),
        // TronGrid's published limit is higher, but one account refresh alone makes a dozen calls;
        // stay well under it, shared by every client of the origin.
        ExactEntry(
            origin: "https://api.trongrid.io",
            provider: .tronGrid,
            policy: RateLimitPolicy(maxCallsPerSecond: 5, maxRetryCount: 3)
        ),
        ExactEntry(
            origin: "https://nile.trongrid.io",
            provider: .tronGrid,
            policy: RateLimitPolicy(maxCallsPerSecond: 5, maxRetryCount: 3)
        ),
        ExactEntry(
            origin: "https://blockstream.info",
            provider: .esplora,
            policy: RateLimitPolicy(maxCallsPerSecond: 1, maxRetryCount: 3)
        )
    ]

    /// Applies to every origin not covered by `exactPolicies` above, for a
    /// given provider kind. `.blockfrost`/`.tronGrid`/`.jsonRPC` are
    /// reactive-only everywhere until a real limit is confirmed per origin.
    static let providerDefaults: [ProviderKind: RateLimitPolicy] = [
        .aptosLabs: .reactiveOnly,
        .blockfrost: .reactiveOnly,
        .blockscout: .reactiveOnly,
        .electrum: .reactiveOnly,
        .esplora: .reactiveOnly,
        .etherscan: .reactiveOnly,
        .jsonRPC: .reactiveOnly,
        .stakewiz: .reactiveOnly,
        .suiGRPC: .reactiveOnly,
        .toncenter: .reactiveOnly,
        .tronGrid: .reactiveOnly
    ]
}

/// The single entry point the rest of WalletKit (and the app target) uses
/// for rate-limit handling — `RateGate` itself stays internal, reachable
/// only through the two methods below.
public final class RateGateRegistry: @unchecked Sendable {
    public static let shared = RateGateRegistry()

    /// Shared by both the policy table and the gate cache: an override or a
    /// gate for one provider kind at some host must never leak to a
    /// different provider kind that happens to share that hostname.
    private struct PolicyKey: Hashable {
        let origin: String
        let provider: ProviderKind
    }

    private let lock = NSLock()
    private let exactPolicies: [PolicyKey: RateLimitPolicy]
    private let providerDefaults: [ProviderKind: RateLimitPolicy]
    private var gates: [PolicyKey: RateGate<ContinuousClock>] = [:]

    /// Not public: only `.shared` is a meaningful instance in production.
    /// Tests construct their own instance with intentionally different
    /// tables to verify resolution follows `provider`, not just `origin`.
    init(
        exactPolicies: [RateLimitPolicy.ExactEntry] = RateLimitPolicy.exactPolicies,
        providerDefaults: [ProviderKind: RateLimitPolicy] = RateLimitPolicy.providerDefaults
    ) {
        let keyed = exactPolicies.map { (PolicyKey(origin: $0.origin, provider: $0.provider), $0.policy) }

        self.exactPolicies = Dictionary(uniqueKeysWithValues: keyed)
        self.providerDefaults = providerDefaults
    }

    /// `origin`: scheme + host + effective port — a self-hosted node on two
    /// different ports is two different services.
    private func policy(for origin: String, provider: ProviderKind) -> RateLimitPolicy {
        let key = PolicyKey(origin: origin, provider: provider)
        return exactPolicies[key] ?? providerDefaults[provider] ?? .reactiveOnly
    }

    /// Every origin has a gate: fixed-rate when its rate is confirmed, otherwise
    /// adaptive (admits freely until the origin signals quota).
    func gate(for origin: String, provider: ProviderKind) -> RateGate<ContinuousClock> {
        let resolved = policy(for: origin, provider: provider)
        let key = PolicyKey(origin: origin, provider: provider)
        lock.lock()
        defer { lock.unlock() }

        if let existing = gates[key] {
            return existing
        }

        let gate = RateGate(clock: ContinuousClock(), maxCallsPerSecond: resolved.maxCallsPerSecond)
        gates[key] = gate
        return gate
    }

    /// A ready-to-attach interceptor for this origin/provider.
    public func makeRetryPolicy(for origin: String, provider: ProviderKind) -> RateLimitRetryPolicy {
        let resolved = policy(for: origin, provider: provider)

        return RateLimitRetryPolicy(
            gate: gate(for: origin, provider: provider),
            maxRetryCount: resolved.maxRetryCount,
            // These report success after classifying the body: quota arrives in-band.
            countsHTTPSuccess: ![.etherscan, .jsonRPC].contains(provider)
        )
    }

    /// A Moya provider whose requests are paced by this origin's gate, in the
    /// ``RequestLane`` of the task that issues each request.
    public func makeProvider<Target: TargetType>(
        origin: String,
        provider: ProviderKind,
        configuration: URLSessionConfiguration = .default
    ) -> MoyaProvider<Target> {
        let policy = makeRetryPolicy(for: origin, provider: provider)

        // Runs synchronously inside `MoyaProvider.request`, on the calling
        // task, so the task-local lane is still readable.
        let requestClosure: MoyaProvider<Target>.RequestClosure = { endpoint, done in
            let lane = RequestLane.current

            MoyaProvider<Target>.defaultRequestMapping(for: endpoint) { result in
                guard case let .success(request) = result else {
                    done(result)
                    return
                }

                let stamped = (request as NSURLRequest).mutableCopy() as? NSMutableURLRequest
                stamped.map { URLProtocol.setProperty(lane.rawValue, forKey: RateLimitRetryPolicy.laneKey, in: $0) }
                done(.success((stamped as URLRequest?) ?? request))
            }
        }

        return MoyaProvider<Target>(
            requestClosure: requestClosure,
            session: Session(configuration: configuration, interceptor: policy, eventMonitors: [policy])
        )
    }

    /// Suspends until the calling task's lane has a slot on this origin, for
    /// transports without a Moya pipeline (gRPC, raw sockets).
    public func acquire(origin: String, provider: ProviderKind) async throws {
        try await gate(for: origin, provider: provider).acquire(lane: RequestLane.current)
    }

    /// The origin reported quota (HTTP 429, `resource_exhausted`, an in-band
    /// error): applies its cooldown and, for an adaptive origin, lowers the pace.
    public func reportQuotaExceeded(origin: String, provider: ProviderKind, retryAfter: Duration?) async {
        let cooldown = min(max(retryAfter ?? .seconds(1), .zero), .seconds(QuotaSignal.maxRetryAfterSeconds))
        await gate(for: origin, provider: provider).penalize(by: cooldown)
    }

    /// Per-lane admission statistics of every gate created so far, keyed `provider@origin`.
    public func admissionStats() async -> [String: [RequestLane: LaneAdmissionStats]] {
        let snapshot = lock.withLock { gates }
        var result: [String: [RequestLane: LaneAdmissionStats]] = [:]

        for (key, gate) in snapshot {
            result["\(key.provider)@\(key.origin)"] = await gate.stats
        }

        return result
    }

    /// One successful, quota-free response from the origin.
    public func reportSuccess(origin: String, provider: ProviderKind) async {
        await gate(for: origin, provider: provider).recordSuccess()
    }

    /// For Etherscan's in-band rate-limit signal, invisible to
    /// `RateLimitRetryPolicy` (it's an HTTP 200 body, not a real failure).
    public func penalize(origin: String, provider: ProviderKind, by duration: Duration) async {
        await reportQuotaExceeded(origin: origin, provider: provider, retryAfter: duration)
    }
}
