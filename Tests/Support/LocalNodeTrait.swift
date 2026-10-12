import Foundation
import Testing

/// Whether the tests are running on a CI runner. Detected via `CI` or
/// `GITHUB_ACTIONS`, both of which GitHub Actions sets.
enum LocalNodeTesting {
    static var isRunningInCI: Bool {
        let environment = ProcessInfo.processInfo.environment
        return environment["CI"] == "true" || environment["GITHUB_ACTIONS"] == "true"
    }
}

extension Trait where Self == ConditionTrait {
    /// Marks a test or suite that spawns a local blockchain node (Anvil,
    /// `sui start`, `solana-test-validator`, bitcoind + electrs).
    ///
    /// Locally these run as normal and fail loudly if the node won't start.
    /// In CI they are skipped entirely: starting a node there depends on
    /// toolchain downloads, runner load and the OS image, none of which the
    /// test controls. The Makefile likewise skips provisioning the Bitcoin
    /// and Solana binaries in CI.
    static var localNode: Self {
        .disabled(if: LocalNodeTesting.isRunningInCI, "Spawns a local node; not run in CI")
    }
}
