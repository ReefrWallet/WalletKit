// Shared `URLProtocol` stub for JSONRPCClientTests/EthereumRPCClientTests —
// lets those exercise the real `URLSession`/`JSONRPCClient` request/response
// path (encoding, HTTP status handling, JSON-RPC envelope decoding) without
// making a real network call.
//
// Each `makeSession(response:)` call gets its own private slot, correlated
// to that session's requests via a header `URLSessionConfiguration.
// httpAdditionalHeaders` stamps onto every request the session makes —
// *not* shared mutable state keyed by the `StubURLProtocol` class itself.
// `URLProtocol` is registered process-wide by class, so two suites'
// sessions both route through the same `StubURLProtocol` instance-per-
// request machinery; sharing the response/captured-request state directly
// on `StubURLProtocol` (e.g. as plain `static var`s) would race the moment
// two suites' tests run concurrently — which Swift Testing does by default
// across suites even when each suite is individually `.serialized`.
import Foundation

final class StubURLProtocol: URLProtocol {
    enum StubResponse {
        case success(statusCode: Int = 200, body: Data)
        case failure(URLError.Code)
    }

    struct Session {
        let urlSession: URLSession
        fileprivate let id: UUID

        var capturedRequest: URLRequest? { StubURLProtocol.state(for: id)?.request }
        var capturedBody: Data? { StubURLProtocol.state(for: id)?.body }
    }

    private struct State {
        let response: StubResponse
        let responsesByPath: [String: StubResponse]?
        var request: URLRequest?
        var body: Data?
    }

    private static let sessionIDHeader = "X-StubURLProtocol-Session-ID"
    private static let lock = NSLock()
    nonisolated(unsafe) private static var statesById: [UUID: State] = [:]

    /// A `URLSession` that serves `response` to every request it makes,
    /// recording the last request/body sent — isolated from any other
    /// session created this way, so concurrently-running tests never
    /// observe each other's stubbed response.
    static func makeSession(response: StubResponse) -> Session {
        let id = UUID()
        lock.withLock { statesById[id] = State(response: response, responsesByPath: nil) }

        let configuration = makeConfiguration(id: id)
        return Session(urlSession: URLSession(configuration: configuration), id: id)
    }

    /// A session that selects a canned response by the request URL path.
    /// Useful for clients whose single operation depends on several HTTP
    /// endpoints, while retaining the per-session isolation of `makeSession`.
    static func makeSession(responsesByPath: [String: StubResponse]) -> Session {
        let id = UUID()
        lock.withLock {
            statesById[id] = State(
                response: .failure(.unknown),
                responsesByPath: responsesByPath
            )
        }

        let configuration = makeConfiguration(id: id)
        return Session(urlSession: URLSession(configuration: configuration), id: id)
    }

    private static func makeConfiguration(id: UUID) -> URLSessionConfiguration {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubURLProtocol.self]
        configuration.httpAdditionalHeaders = [sessionIDHeader: id.uuidString]
        return configuration
    }

    private static func state(for id: UUID) -> State? {
        lock.withLock { statesById[id] }
    }

    override static func canInit(with request: URLRequest) -> Bool { true }
    override static func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard
            let idString = request.value(forHTTPHeaderField: Self.sessionIDHeader),
            let id = UUID(uuidString: idString),
            let state = Self.state(for: id)
        else {
            client?.urlProtocol(self, didFailWithError: URLError(.unknown))
            return
        }

        let response = state.responsesByPath?[request.url?.path ?? ""] ?? state.response

        let body = Self.bodyData(of: request)
        let capturedRequest = request
        Self.lock.withLock {
            Self.statesById[id]?.request = capturedRequest
            Self.statesById[id]?.body = body
        }

        switch response {
        case let .success(statusCode, responseBody):
            let httpResponse = HTTPURLResponse(
                url: request.url!,
                statusCode: statusCode,
                httpVersion: "HTTP/1.1",
                headerFields: nil
            )!
            client?.urlProtocol(self, didReceive: httpResponse, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: responseBody)
            client?.urlProtocolDidFinishLoading(self)
        case .failure(let code):
            client?.urlProtocol(self, didFailWithError: URLError(code))
        }
    }

    override func stopLoading() {}

    // `URLProtocol.request.httpBody` is `nil` for a request that's already
    // been handed to `URLSession` for delivery — the body only survives as
    // `httpBodyStream` by this point.
    private static func bodyData(of request: URLRequest) -> Data? {
        if let body = request.httpBody { return body }

        guard let stream = request.httpBodyStream else { return nil }
        stream.open()
        defer { stream.close() }

        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while stream.hasBytesAvailable {
            let bytesRead = stream.read(&buffer, maxLength: buffer.count)
            guard bytesRead > 0 else { break }
            data.append(buffer, count: bytesRead)
        }
        return data
    }
}
