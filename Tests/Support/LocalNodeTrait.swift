import Foundation
import Testing

/// Lets a test that spawns a local blockchain node (Anvil, `sui start`,
/// `solana-test-validator`, bitcoind + electrs) fail without failing a CI
/// run.
///
/// Locally these tests still fail loudly: a node that won't start is a real
/// problem on a developer machine. On a CI runner, though, starting a node
/// depends on toolchain downloads, runner load and the OS image, none of
/// which the test controls. So under CI the whole test (or each test in a
/// suite) runs inside `withKnownIssue(isIntermittent: true)`: any thrown
/// error or failed expectation is recorded as a known issue rather than a
/// failure, and a passing run is still fine.
///
/// CI is detected via `CI` or `GITHUB_ACTIONS` (both set by GitHub
/// Actions). `xcodebuild` only forwards `TEST_RUNNER_`-prefixed variables
/// to the test process, so an Xcode-driven CI run must set
/// `TEST_RUNNER_CI=true`.
struct LocalNodeTrait: TestTrait, SuiteTrait, TestScoping {
    var isRecursive: Bool { true }

    static var isRunningInCI: Bool {
        let environment = ProcessInfo.processInfo.environment
        return environment["CI"] == "true" || environment["GITHUB_ACTIONS"] == "true"
    }

    func scopeProvider(for test: Test, testCase: Test.Case?) -> Self? {
        // Scope each test case, not the suite around them, and only in CI.
        testCase != nil && Self.isRunningInCI ? self : nil
    }

    func provideScope(
        for test: Test,
        testCase: Test.Case?,
        performing function: @Sendable () async throws -> Void
    ) async throws {
        await withKnownIssue("spawns a local node, which is allowed to fail in CI", isIntermittent: true) {
            try await function()
        }
    }
}

extension Trait where Self == LocalNodeTrait {
    /// Marks a test or suite that spawns a local blockchain node, allowing
    /// it to fail in CI. See ``LocalNodeTrait``.
    static var localNode: Self { Self() }
}
