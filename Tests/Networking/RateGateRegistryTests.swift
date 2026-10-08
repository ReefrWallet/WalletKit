// Tests for Sources/WalletKit/Networking/RateGateRegistry.swift. Uses an
// instance constructed with intentionally different per-provider defaults
// (independent of what ships in production, where every provider default
// happens to be reactive-only) so resolution-by-provider is actually
// exercised, not just resolution-by-origin.

import Testing
@testable import WalletKit

struct RateGateRegistryTests {
    private static let proactive = RateLimitPolicy(maxCallsPerSecond: 9, maxRetryCount: 5)
    private static let reactiveOnly = RateLimitPolicy(maxCallsPerSecond: nil, maxRetryCount: 2)

    private func makeRegistry() -> RateGateRegistry {
        RateGateRegistry(
            exactPolicies: [],
            providerDefaults: [.etherscan: Self.proactive, .blockfrost: Self.reactiveOnly]
        )
    }

    @Test func unlistedOriginResolvesByProviderNotJustByBeingUnlisted() {
        let registry = makeRegistry()

        let etherscanPolicy = registry.makeRetryPolicy(for: "https://custom.example.com", provider: .etherscan)
        let blockfrostPolicy = registry.makeRetryPolicy(for: "https://custom.example.com", provider: .blockfrost)

        // Same origin, different provider kinds — must resolve to each
        // provider's own default, not whichever one happens to be looked
        // up first for that origin.
        #expect(etherscanPolicy.gate != nil)
        #expect(etherscanPolicy.maxRetryCount == 5)
        #expect(blockfrostPolicy.gate == nil)
        #expect(blockfrostPolicy.maxRetryCount == 2)
    }

    @Test func exactOriginOverrideIsScopedToItsOwnProviderKind() {
        let registry = RateGateRegistry(
            exactPolicies: [
                RateLimitPolicy.ExactEntry(origin: "https://shared-host.example.com", provider: .etherscan, policy: Self.proactive)
            ],
            providerDefaults: [.blockfrost: Self.reactiveOnly]
        )

        // A different provider kind at the same host must fall through to
        // its own provider default, not the exact override meant for
        // `.etherscan`.
        let etherscanPolicy = registry.makeRetryPolicy(for: "https://shared-host.example.com", provider: .etherscan)
        let blockfrostPolicy = registry.makeRetryPolicy(for: "https://shared-host.example.com", provider: .blockfrost)

        #expect(etherscanPolicy.gate != nil)
        #expect(etherscanPolicy.maxRetryCount == 5)
        #expect(blockfrostPolicy.gate == nil)
        #expect(blockfrostPolicy.maxRetryCount == 2)
    }

    @Test func unconfiguredProviderAndOriginFallBackToReactiveOnly() {
        let registry = RateGateRegistry(exactPolicies: [], providerDefaults: [:])

        let policy = registry.makeRetryPolicy(for: "https://anything.example.com", provider: .tronGrid)

        #expect(policy.gate == nil)
    }

    @Test func penalizingAProviderWithNoConfiguredGateIsANoOp() async {
        let registry = makeRegistry()

        // `.blockfrost` is reactive-only in this registry — penalizing it
        // must not throw or crash, just do nothing.
        await registry.penalize(origin: "https://custom.example.com", provider: .blockfrost, by: .seconds(5))
    }
}
