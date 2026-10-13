import Foundation

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
    case esplora
    case etherscan
    case jsonRPC
    case tronGrid
}

/// `maxCallsPerSecond == nil` means reactive retry only (HTTP 429/503 with
/// backoff) and no proactive pacing — the deliberate default for providers
/// (or origins) whose real rate limit hasn't been confirmed. Assigning a
/// guessed proactive rate has a real cost (throttling a local node or a
/// generous provider as if it were the strictest one), so a rate is only
/// ever added once it's known, not assumed.
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
        .esplora: .reactiveOnly,
        .etherscan: .reactiveOnly,
        .jsonRPC: .reactiveOnly,
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

    private func gate(for origin: String, provider: ProviderKind) -> RateGate<ContinuousClock>? {
        let resolved = policy(for: origin, provider: provider)

        guard let rate = resolved.maxCallsPerSecond else {
            return nil
        }

        let key = PolicyKey(origin: origin, provider: provider)
        lock.lock()
        defer { lock.unlock() }

        if let existing = gates[key] {
            return existing
        }

        let gate = RateGate(clock: ContinuousClock(), maxCallsPerSecond: rate)
        gates[key] = gate
        return gate
    }

    /// The only thing a client needs: a ready-to-attach interceptor for
    /// this origin/provider, proactive pacing included when configured.
    public func makeRetryPolicy(for origin: String, provider: ProviderKind) -> RateLimitRetryPolicy {
        let resolved = policy(for: origin, provider: provider)
        return RateLimitRetryPolicy(gate: gate(for: origin, provider: provider), maxRetryCount: resolved.maxRetryCount)
    }

    /// For Etherscan's in-band rate-limit signal, invisible to
    /// `RateLimitRetryPolicy` (it's an HTTP 200 body, not a real failure) —
    /// pushes the same gate the interceptor uses, if one is configured for
    /// this origin/provider; a no-op otherwise.
    public func penalize(origin: String, provider: ProviderKind, by duration: Duration) async {
        await gate(for: origin, provider: provider)?.penalize(by: duration)
    }
}
