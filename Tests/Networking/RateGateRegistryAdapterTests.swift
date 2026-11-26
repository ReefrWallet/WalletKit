// Extra adapters and event monitors passed to `RateGateRegistry.makeProvider`.

import Alamofire
import Foundation
import Moya
import Synchronization
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

/// Records each attempt's lane and whether the gate admitted it first.
private final class RecordingAdapter: RequestAdapter, EventMonitor, Sendable {
    let cancelled = Mutex(0)
    let lanes = Mutex<[String?]>([])

    func adapt(
        _ urlRequest: URLRequest,
        for session: Session,
        completion: @escaping @Sendable (Result<URLRequest, any Error>) -> Void
    ) {
        let lane = URLProtocol.property(forKey: RateLimitRetryPolicy.laneKey, in: urlRequest) as? String
        lanes.withLock { $0.append(lane) }
        completion(.success(urlRequest))
    }

    func requestDidCancel(_ request: Request) {
        cancelled.withLock { $0 += 1 }
    }
}

struct RateGateRegistryAdapterTests {
    private static let origin = "https://example.com"

    private func makeRegistry(rate: Double?) -> RateGateRegistry {
        RateGateRegistry(
            exactPolicies: [],
            providerDefaults: [.tronGrid: RateLimitPolicy(maxCallsPerSecond: rate, maxRetryCount: 3)]
        )
    }

    @Test func extraAdaptersRunAfterTheGateOnEveryAttempt() async throws {
        let registry = makeRegistry(rate: 1000)
        let adapter = RecordingAdapter()
        let stub = StubURLProtocol.makeSession(
            responseSequence: [.success(statusCode: 429, body: Data()), .success(body: Data("ok".utf8))]
        )

        let provider: MoyaProvider<PingTarget> = registry.makeProvider(
            origin: Self.origin,
            provider: .tronGrid,
            configuration: stub.urlSession.configuration,
            adapters: [adapter],
            eventMonitors: [adapter]
        )

        _ = try await RequestLane.$current.withValue(.backfill) {
            try await provider.requestData(PingTarget())
        }

        #expect(adapter.lanes.withLock { $0 } == ["backfill", "backfill"])
        #expect(stub.capturedRequests.count == 2)
        #expect(await registry.gate(for: Self.origin, provider: .tronGrid).admittedByLane[.backfill] == 2)
    }

    @Test func thePolicyStillCancelsAQueuedRequest() async throws {
        let registry = makeRegistry(rate: 0.5)
        let adapter = RecordingAdapter()
        let stub = StubURLProtocol.makeSession(response: .success(body: Data("ok".utf8)))
        let provider: MoyaProvider<PingTarget> = registry.makeProvider(
            origin: Self.origin,
            provider: .tronGrid,
            configuration: stub.urlSession.configuration,
            adapters: [adapter],
            eventMonitors: [adapter]
        )

        _ = try await provider.requestData(PingTarget()) // takes the first slot

        let queued = _Concurrency.Task { try await provider.requestData(PingTarget()) }
        try await _Concurrency.Task.sleep(for: .milliseconds(100))
        queued.cancel()

        await #expect(throws: CancellationError.self) {
            try await queued.value
        }

        // Monitors hear of the cancel asynchronously, after the task has thrown.
        for _ in 0..<200 where adapter.cancelled.withLock({ $0 }) == 0 {
            try await _Concurrency.Task.sleep(for: .milliseconds(10))
        }

        #expect(adapter.cancelled.withLock { $0 } == 1)
        #expect(adapter.lanes.withLock { $0.count } == 1)
        #expect(stub.capturedRequests.count == 1)
    }
}
