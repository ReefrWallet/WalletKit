// Tests for Sources/WalletKit/Networking/RateLimitRetryPolicy.swift.
// `retryAfterSeconds`/`backoffSeconds` are exercised directly; the
// retry/penalize behavior is exercised end-to-end through a real
// `Alamofire.Session` wired to `StubURLProtocol`, matching how
// `JSONRPCClientTests` exercises the real `URLSession` pipeline rather than
// mocking Alamofire's `Request` type (which has no public initializer).

import Alamofire
import Foundation
import Testing
@testable import WalletKit

struct RateLimitRetryPolicyTests {
    private static let url = URL(string: "https://example.com/rate-limited")!

    // MARK: - Retry-After parsing

    @Test func retryAfterParsesANumericHeader() {
        let response = HTTPURLResponse(
            url: Self.url, statusCode: 429, httpVersion: nil, headerFields: ["Retry-After": "7"]
        )!
        #expect(RateLimitRetryPolicy.retryAfterSeconds(response: response) == 7)
    }

    @Test func retryAfterParsesAnHTTPDateHeader() throws {
        let future = Date().addingTimeInterval(10)
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "GMT")
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"

        let response = HTTPURLResponse(
            url: Self.url,
            statusCode: 429,
            httpVersion: nil,
            headerFields: ["Retry-After": formatter.string(from: future)]
        )!

        let seconds = try #require(RateLimitRetryPolicy.retryAfterSeconds(response: response))
        #expect(seconds > 8 && seconds <= 10)
    }

    @Test func retryAfterIsNilWhenTheHeaderIsAbsentOrMalformed() {
        let missing = HTTPURLResponse(url: Self.url, statusCode: 429, httpVersion: nil, headerFields: nil)!
        #expect(RateLimitRetryPolicy.retryAfterSeconds(response: missing) == nil)

        let malformed = HTTPURLResponse(
            url: Self.url,
            statusCode: 429,
            httpVersion: nil,
            headerFields: ["Retry-After": "not-a-date-or-number"]
        )!
        #expect(RateLimitRetryPolicy.retryAfterSeconds(response: malformed) == nil)
    }

    // MARK: - Backoff

    @Test func backoffGrowsExponentiallyWithoutJitter() {
        #expect(RateLimitRetryPolicy.backoffSeconds(attempt: 0, baseDelay: 1, jitter: 1) == 1)
        #expect(RateLimitRetryPolicy.backoffSeconds(attempt: 1, baseDelay: 1, jitter: 1) == 2)
        #expect(RateLimitRetryPolicy.backoffSeconds(attempt: 2, baseDelay: 1, jitter: 1) == 4)
    }

    // MARK: - End-to-end retry behavior

    @Test func retriesA429ThenSucceeds() async throws {
        let stub = StubURLProtocol.makeSession(
            responseSequence: [.success(statusCode: 429, body: Data()), .success(body: Data("ok".utf8))]
        )

        let policy = RateLimitRetryPolicy(
            gate: nil,
            maxRetryCount: 3,
            maxRetryAfter: .milliseconds(10),
            jitterSource: { 1 }
        )

        let session = Session(configuration: stub.urlSession.configuration, interceptor: policy)

        let data = try await Self.performRequest(session)
        #expect(String(data: data, encoding: .utf8) == "ok")
    }

    @Test func retriesA503ThenSucceeds() async throws {
        let stub = StubURLProtocol.makeSession(
            responseSequence: [.success(statusCode: 503, body: Data()), .success(body: Data("ok".utf8))]
        )

        let policy = RateLimitRetryPolicy(
            gate: nil, maxRetryCount: 3, maxRetryAfter: .milliseconds(10), jitterSource: { 1 }
        )

        let session = Session(configuration: stub.urlSession.configuration, interceptor: policy)

        let data = try await Self.performRequest(session)
        #expect(String(data: data, encoding: .utf8) == "ok")
    }

    @Test func givesUpAfterMaxRetryCount() async throws {
        let stub = StubURLProtocol.makeSession(responseSequence: [.success(statusCode: 429, body: Data())])

        let policy = RateLimitRetryPolicy(
            gate: nil, maxRetryCount: 2, maxRetryAfter: .milliseconds(10), jitterSource: { 1 }
        )

        let session = Session(configuration: stub.urlSession.configuration, interceptor: policy)

        await #expect(throws: (any Error).self) {
            try await Self.performRequest(session)
        }
    }

    @Test func a429RetryPenalizesTheSharedGate() async throws {
        let gate = RateGate(clock: ContinuousClock(), maxCallsPerSecond: 1000)
        // A long, uncapped retry delay (no `Retry-After` header, so this
        // falls back to `backoffSeconds(attempt: 0, jitter: 1)` == 1s) —
        // checking *after* `performRequest` completes wouldn't work, since
        // Alamofire's own retry wait already consumes exactly the duration
        // the gate was penalized by, so nothing "extra" is observable by
        // then. Instead, check the gate mid-flight, well before that wait
        // elapses.
        let policy = RateLimitRetryPolicy(
            gate: gate, maxRetryCount: 3,
            maxRetryAfter: .seconds(10),
            jitterSource: { 1 }
        )

        let stub = StubURLProtocol.makeSession(
            responseSequence: [.success(statusCode: 429, body: Data()), .success(body: Data("ok".utf8))]
        )

        let session = Session(configuration: stub.urlSession.configuration, interceptor: policy)

        let requestTask = Task { try await Self.performRequest(session) }
        defer { requestTask.cancel() }

        // Long enough for the local stub round trip + `retry()` handler to
        // have fired, short enough to stay well inside the ~1s retry wait.
        try await Task.sleep(for: .milliseconds(100))

        let remaining = await gate.nextAllowedTime - ContinuousClock.now
        #expect(remaining > .milliseconds(500))
    }

    @Test func a503RetryDoesNotPenalizeTheSharedGate() async throws {
        let gate = RateGate(clock: ContinuousClock(), maxCallsPerSecond: 1000)
        let policy = RateLimitRetryPolicy(
            gate: gate,
            maxRetryCount: 3,
            maxRetryAfter: .milliseconds(150),
            jitterSource: { 1 }
        )

        let stub = StubURLProtocol.makeSession(
            responseSequence: [.success(statusCode: 503, body: Data()), .success(body: Data("ok".utf8))]
        )

        let session = Session(configuration: stub.urlSession.configuration, interceptor: policy)

        _ = try await Self.performRequest(session)

        let deadline = await gate.nextAllowedTime
        #expect(deadline < ContinuousClock.now.advanced(by: .milliseconds(50)))
    }

    private static func performRequest(_ session: Session) async throws -> Data {
        try await withCheckedThrowingContinuation { continuation in
            session.request(url).validate(statusCode: 200 ..< 300).responseData { response in
                continuation.resume(with: response.result)
            }
        }
    }
}
