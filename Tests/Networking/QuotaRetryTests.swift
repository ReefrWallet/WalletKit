// Retry paths of the transports without a Moya pipeline: Sui gRPC's `rpc`
// helper and Electrum's gated `call`. Each test uses its own origin and a
// fixed-rate registry with a millisecond backoff, so nothing is shared or slow.

import Foundation
import GRPCCore
import Testing
@testable import WalletKit

private actor Counter {
    private(set) var calls: [String] = []

    func record(_ call: String) {
        calls.append(call)
    }
}

private func fastContext(provider: ProviderKind) -> QuotaRetryContext {
    QuotaRetryContext(
        registry: RateGateRegistry(
            exactPolicies: [],
            providerDefaults: [provider: RateLimitPolicy(maxCallsPerSecond: 1000, maxRetryCount: 0)]
        ),
        backoff: { _ in .milliseconds(5) }
    )
}

struct SuiRetryTests {
    private func makeClient() -> SuiGRPCClient {
        var client = SuiGRPCClient(host: "retry-\(UUID().uuidString.lowercased()).example.com")
        client.retryContext = fastContext(provider: .suiGRPC)
        return client
    }

    private func exhausted() -> RPCError {
        RPCError(code: .resourceExhausted, message: "quota")
    }

    @Test func aReadIsReplayedAfterResourceExhausted() async throws {
        let client = makeClient()
        let log = Counter()

        let value: Int = try await client.rpc(.read) {
            await log.record("call")

            if await log.calls.count < 3 {
                throw exhausted()
            }

            return 7
        }

        #expect(value == 7)
        #expect(await log.calls.count == 3)
    }

    @Test func aReadGivesUpAfterTheRetryBudgetWithAQuotaError() async throws {
        let client = makeClient()
        let log = Counter()

        await #expect(throws: BlockchainClientError.self) {
            let _: Int = try await client.rpc(.read) {
                await log.record("call")
                throw exhausted()
            }
        }

        #expect(await log.calls.count == SuiGRPCClient.maxQuotaRetries + 1)
    }

    @Test func aSubmissionIsReportedButNeverReplayed() async throws {
        let client = makeClient()
        let log = Counter()

        do {
            let _: Int = try await client.rpc(.submit) {
                await log.record("call")
                throw exhausted()
            }

            Issue.record("expected a throw")
        } catch let error as BlockchainClientError {
            #expect(error.isQuotaExceeded)
        }

        #expect(await log.calls.count == 1)
    }

    @Test func onlyTheFailedPageOfAPaginationLoopIsReplayed() async throws {
        let client = makeClient()
        let log = Counter()
        var pageToken = 0
        var failedOnce = false

        repeat {
            let page = pageToken
            let next: Int = try await client.rpc(.read) {
                await log.record("page \(page)")

                if page == 1, !failedOnce {
                    failedOnce = true
                    throw exhausted()
                }

                return page + 1
            }

            pageToken = next == 3 ? 0 : next
        } while pageToken != 0

        #expect(await log.calls == ["page 0", "page 1", "page 1", "page 2"])
    }

    @Test func otherRPCErrorsAreNotRetried() async throws {
        let client = makeClient()
        let log = Counter()

        await #expect(throws: RPCError.self) {
            let _: Int = try await client.rpc(.read) {
                await log.record("call")
                throw RPCError(code: .unavailable, message: "down")
            }
        }

        #expect(await log.calls.count == 1)
    }

    @Test func resourceExhaustedMapsToQuotaExceededAndCancellationPassesThrough() async throws {
        let client = makeClient()

        do {
            try await client.withRemappedErrors {
                throw exhausted()
            }

            Issue.record("expected a throw")
        } catch let error as BlockchainClientError {
            let code = RPCError.Code.resourceExhausted.rawValue
            #expect(error == .quotaExceeded(code: code, message: "quota", retryAfter: nil))
        }

        await #expect(throws: CancellationError.self) {
            try await client.withRemappedErrors {
                throw CancellationError()
            }
        }
    }
}

struct ElectrumRetryTests {
    private func makeConnection(
        replies: @escaping @Sendable (String, Int) async throws -> Any,
        log: Counter
    ) async -> ElectrumConnection {
        let connection = ElectrumConnection(
            host: "retry-\(UUID().uuidString.lowercased()).example.com",
            port: 50002,
            useTLS: true,
            sendOverride: { method, _ in
                await log.record(method)
                return try await replies(method, await log.calls.count)
            }
        )

        await connection.setRetryContext(fastContext(provider: .electrum))
        return connection
    }

    private static let quota = BlockchainClientError.quotaExceeded(
        code: -101,
        message: "excessive resource usage",
        retryAfter: nil
    )

    @Test func aQuotaReplyIsReplayedAndTheSecondAttemptSucceeds() async throws {
        let log = Counter()
        let connection = await makeConnection(
            replies: { _, count in
                if count == 1 {
                    throw Self.quota
                }

                return "ok"
            },
            log: log
        )

        let result = try await connection.call(method: "blockchain.scripthash.get_history", params: ["x"])

        #expect(result as? String == "ok")
        #expect(await log.calls.count == 2)
    }

    @Test func aBroadcastIsNeverReplayed() async throws {
        let log = Counter()
        let connection = await makeConnection(
            replies: { _, _ in
                throw Self.quota
            },
            log: log
        )

        await #expect(throws: BlockchainClientError.self) {
            _ = try await connection.call(method: "blockchain.transaction.broadcast", params: ["00"])
        }

        #expect(await log.calls.count == 1)
    }

    @Test func otherErrorsAreNotReplayed() async throws {
        let log = Counter()
        let connection = await makeConnection(
            replies: { _, _ in
                throw BlockchainClientError.rpcError(code: 1, message: "bad request")
            },
            log: log
        )

        await #expect(throws: BlockchainClientError.self) {
            _ = try await connection.call(method: "blockchain.headers.subscribe", params: [])
        }

        #expect(await log.calls.count == 1)
    }

    @Test func onlyElectrumXsExcessiveResourceUsageReplyIsQuota() {
        #expect(ElectrumConnection.isQuotaReply(code: -101, message: "excessive resource usage"))
        #expect(!ElectrumConnection.isQuotaReply(code: 1, message: "excessive resource usage"))
        #expect(!ElectrumConnection.isQuotaReply(code: -101, message: "unknown method"))
        #expect(!ElectrumConnection.isQuotaReply(code: 2, message: "server busy"))
    }
}

struct SuiSubscriptionRetryTests {
    private static let quota = BlockchainClientError.quotaExceeded(
        code: RPCError.Code.resourceExhausted.rawValue,
        message: "quota",
        retryAfter: nil
    )

    private func makeClient() -> (SuiGRPCClient, origin: String) {
        let host = "retry-\(UUID().uuidString.lowercased()).example.com"
        var client = SuiGRPCClient(host: host)
        client.retryContext = fastContext(provider: .suiGRPC)
        return (client, "grpc://\(host):443")
    }

    /// Runs `subscribe` through the retry loop and collects what the stream yields.
    private func run(
        _ client: SuiGRPCClient,
        subscribe: @escaping (@escaping (BlockchainTransactionHead) -> Void) async throws -> Void
    ) async -> (heads: [UInt64], error: (any Error)?) {
        var continuation: AsyncThrowingStream<BlockchainTransactionHead, any Error>.Continuation!
        let stream = AsyncThrowingStream<BlockchainTransactionHead, any Error> { continuation = $0 }

        do {
            try await client.runSubscription(yielding: continuation, subscribe: subscribe)
            continuation.finish()
        } catch {
            continuation.finish(throwing: error)
        }

        var heads: [UInt64] = []
        do {
            for try await head in stream {
                heads.append(head.height)
            }
        } catch {
            return (heads, error)
        }

        return (heads, nil)
    }

    @Test func aStreamThatFailsAfterItsFirstHeadReportsQuotaAndPropagatesWithoutReplay() async throws {
        var (client, origin) = makeClient()
        client.retryContext.backoff = { _ in .seconds(30) }
        let log = Counter()

        let outcome = await run(client) { deliver in
            await log.record("open")
            deliver(BlockchainTransactionHead(height: 42))
            throw Self.quota
        }

        #expect(outcome.heads == [42])
        #expect((outcome.error as? BlockchainClientError)?.isQuotaExceeded == true)
        #expect(await log.calls.count == 1)

        // The failure reached the gate, so the polling fallback waits out the cooldown.
        let stats = await client.retryContext.registry.admissionStats()
        #expect(stats["suiGRPC@\(origin)"]?[.interactive]?.count == 1)
        #expect(await client.retryContext.registry.gate(for: origin, provider: .suiGRPC).cooldownIsActive)
    }

    @Test func aQuotaErrorBeforeAnyHeadIsRetriedUntilTheStreamOpens() async throws {
        let (client, _) = makeClient()
        let log = Counter()

        let outcome = await run(client) { deliver in
            await log.record("open")

            if await log.calls.count < 3 {
                throw Self.quota
            }

            deliver(BlockchainTransactionHead(height: 7))
        }

        #expect(outcome.heads == [7])
        #expect(outcome.error == nil)
        #expect(await log.calls.count == 3)
    }

    @Test func otherStreamErrorsAreNotRetried() async throws {
        let (client, _) = makeClient()
        let log = Counter()

        let outcome = await run(client) { _ in
            await log.record("open")
            throw BlockchainClientError.rpcError(code: 14, message: "unavailable")
        }

        #expect(outcome.heads.isEmpty)
        #expect(outcome.error as? BlockchainClientError == .rpcError(code: 14, message: "unavailable"))
        #expect(await log.calls.count == 1)
    }
}
