// End-to-end lane capture, cancellation and success counting through a real
// `MoyaProvider` / Alamofire `Session` backed by `StubURLProtocol`.

import Alamofire
import Foundation
import Moya
import Testing
@testable import WalletKit

private struct PingTarget: TargetType {
    var baseURL: URL { URL(string: "https://example.com")! }
    var path: String { "/ping" }
    var method: Moya.Method { .get }
    var task: Moya.Task { .requestPlain }
    var headers: [String: String]? { nil }
    var validationType: ValidationType { .successCodes }
    var sampleData: Data { Data() }
}

private func settle() async {
    try? await _Concurrency.Task.sleep(for: .milliseconds(150))
}

struct RequestLaneHTTPTests {
    private static let origin = "https://example.com"

    private func makeRegistry(rate: Double?) -> RateGateRegistry {
        RateGateRegistry(
            exactPolicies: [],
            providerDefaults: [.tronGrid: RateLimitPolicy(maxCallsPerSecond: rate, maxRetryCount: 3)]
        )
    }

    private func lane(of request: URLRequest) -> String? {
        URLProtocol.property(forKey: RateLimitRetryPolicy.laneKey, in: request) as? String
    }

    @Test func theLaneReachesTheGateOnTheFirstAttemptAndOnTheRetry() async throws {
        let registry = makeRegistry(rate: 1000)
        let stub = StubURLProtocol.makeSession(
            responseSequence: [.success(statusCode: 429, body: Data()), .success(body: Data("ok".utf8))]
        )

        let provider: MoyaProvider<PingTarget> = registry.makeProvider(
            origin: Self.origin,
            provider: .tronGrid,
            configuration: stub.urlSession.configuration
        )

        _ = try await RequestLane.$current.withValue(.backfill) {
            try await provider.requestData(PingTarget())
        }

        #expect(stub.capturedRequests.count == 2)
        #expect(stub.capturedRequests.map(lane(of:)) == ["backfill", "backfill"])
        #expect(await registry.gate(for: Self.origin, provider: .tronGrid).admittedByLane[.backfill] == 2)
    }

    @Test func unlabelledRequestsAreInteractive() async throws {
        let registry = makeRegistry(rate: 1000)
        let stub = StubURLProtocol.makeSession(response: .success(body: Data("ok".utf8)))
        let provider: MoyaProvider<PingTarget> = registry.makeProvider(
            origin: Self.origin,
            provider: .tronGrid,
            configuration: stub.urlSession.configuration
        )

        _ = try await provider.requestData(PingTarget())

        #expect(await registry.gate(for: Self.origin, provider: .tronGrid).admittedByLane[.interactive] == 1)
    }

    @Test func aTerminal429StillSlowsTheGate() async throws {
        let gate = RateGate(clock: ContinuousClock(), maxCallsPerSecond: nil)
        let policy = RateLimitRetryPolicy(gate: gate, maxRetryCount: 0, jitterSource: { 1 })
        let stub = StubURLProtocol.makeSession(response: .success(statusCode: 429, body: Data()))
        let provider = MoyaProvider<PingTarget>(
            session: Session(configuration: stub.urlSession.configuration, interceptor: policy, eventMonitors: [policy])
        )

        await #expect(throws: (any Error).self) {
            try await provider.requestData(PingTarget())
        }

        #expect(await gate.mode == .paced)
    }

    @Test func onlyQuotaFreeSuccessfulResponsesCountTowardRecovery() async throws {
        let registry = makeRegistry(rate: nil)
        let stub = StubURLProtocol.makeSession(
            responseSequence: [.success(statusCode: 503, body: Data()), .success(body: Data("ok".utf8))]
        )

        let provider: MoyaProvider<PingTarget> = registry.makeProvider(
            origin: Self.origin,
            provider: .tronGrid,
            configuration: stub.urlSession.configuration
        )

        _ = try await provider.requestData(PingTarget())
        await settle()

        #expect(await registry.gate(for: Self.origin, provider: .tronGrid).recordedSuccesses == 1)
    }

    @Test func cancellingDuringARetryDelayReturnsPromptlyAndSendsNoSecondRequest() async throws {
        let gate = RateGate(clock: ContinuousClock(), maxCallsPerSecond: 1000)
        let policy = RateLimitRetryPolicy(
            gate: gate,
            maxRetryCount: 3,
            maxRetryAfter: .seconds(5),
            jitterSource: { 1 }
        )

        let stub = StubURLProtocol.makeSession(
            responseSequence: [.success(statusCode: 429, body: Data()), .success(body: Data("ok".utf8))]
        )

        let provider = MoyaProvider<PingTarget>(
            session: Session(configuration: stub.urlSession.configuration, interceptor: policy, eventMonitors: [policy])
        )

        let request = _Concurrency.Task { try await provider.requestData(PingTarget()) }
        defer { request.cancel() }

        while stub.capturedRequests.isEmpty {
            try await _Concurrency.Task.sleep(for: .milliseconds(10))
        }

        try await _Concurrency.Task.sleep(for: .milliseconds(200)) // inside the ~1 s retry delay
        let started = ContinuousClock.now
        request.cancel()

        await #expect(throws: CancellationError.self) {
            try await request.value
        }

        #expect(ContinuousClock.now - started < .milliseconds(500))

        try await _Concurrency.Task.sleep(for: .milliseconds(1_500))
        #expect(stub.capturedRequests.count == 1)
        #expect(!policy.hasPendingState)
    }

    @Test func cancellingAQueuedRequestFreesItsSlotForTheNextOne() async throws {
        let gate = RateGate(clock: ContinuousClock(), maxCallsPerSecond: 2) // 500 ms apart
        let policy = RateLimitRetryPolicy(gate: gate, maxRetryCount: 3, jitterSource: { 1 })
        let stub = StubURLProtocol.makeSession(response: .success(body: Data("ok".utf8)))
        let provider = MoyaProvider<PingTarget>(
            session: Session(configuration: stub.urlSession.configuration, interceptor: policy, eventMonitors: [policy])
        )

        _ = try await provider.requestData(PingTarget()) // takes the first slot

        let cancelled = _Concurrency.Task { try await provider.requestData(PingTarget()) }
        try await _Concurrency.Task.sleep(for: .milliseconds(100))
        let live = _Concurrency.Task { try await provider.requestData(PingTarget()) }
        try await _Concurrency.Task.sleep(for: .milliseconds(100))

        cancelled.cancel()
        await #expect(throws: CancellationError.self) {
            try await cancelled.value
        }

        let started = ContinuousClock.now
        _ = try await live.value

        // The live request takes the slot ~500 ms after the first, not a second one later.
        #expect(ContinuousClock.now - started < .milliseconds(700))
        #expect(stub.capturedRequests.count == 2)
    }
}
