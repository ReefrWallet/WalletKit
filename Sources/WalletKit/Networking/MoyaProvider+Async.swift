import Foundation
import Moya

/// `async`/`await` entry points for `MoyaProvider`, cancellation-aware: if
/// the calling `Task` is cancelled, the underlying Moya `Cancellable` is
/// cancelled too, rather than left running unobserved.
public extension MoyaProvider {
    /// Cancelling the calling task resumes the caller with `CancellationError`
    /// at once, rather than waiting on Alamofire, which can skip its completion
    /// callback when a request is cancelled during a retry delay.
    func requestResponse(_ target: Target) async throws -> Response {
        let box = CancellableBox()

        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                box.set(continuation)

                let cancellable = self.request(target) { result in
                    box.resume(with: result.mapError { $0 as Error })
                }

                box.set(cancellable)
            }
        } onCancel: {
            box.cancel()
        }
    }

    func requestData(_ target: Target) async throws -> Data {
        try await requestResponse(target).data
    }

    func requestDecodable<T: Decodable>(_ target: Target, decoder: JSONDecoder = JSONDecoder()) async throws -> T {
        let response = try await requestResponse(target)

        do {
            return try decoder.decode(T.self, from: response.data)
        } catch {
            throw MoyaError.objectMapping(error, response)
        }
    }

    func requestJSONObject(_ target: Target) async throws -> [String: Any] {
        let response = try await requestResponse(target)

        guard let object = try JSONSerialization.jsonObject(with: response.data) as? [String: Any] else {
            throw MoyaError.jsonMapping(response)
        }

        return object
    }
}

/// Bridges a `Moya.Cancellable` (produced synchronously inside the
/// continuation closure) to `onCancel` (invoked from a different execution
/// context, possibly before the `Cancellable` even exists yet), and resumes
/// the continuation exactly once whichever of result or cancellation wins.
private final class CancellableBox: @unchecked Sendable {
    private let lock = NSLock()
    private var cancellable: Moya.Cancellable?
    private var continuation: CheckedContinuation<Response, Error>?
    private var isCancelled = false
    private var isResumed = false

    func set(_ continuation: CheckedContinuation<Response, Error>) {
        lock.lock()
        let cancelled = isCancelled
        if !cancelled {
            self.continuation = continuation
        } else {
            isResumed = true
        }

        lock.unlock()

        if cancelled {
            continuation.resume(throwing: CancellationError())
        }
    }

    func set(_ cancellable: Moya.Cancellable) {
        lock.lock()
        defer { lock.unlock() }

        if isCancelled {
            cancellable.cancel()
        } else {
            self.cancellable = cancellable
        }
    }

    func resume(with result: Result<Response, Error>) {
        lock.lock()
        let pending = isResumed ? nil : continuation
        isResumed = true
        continuation = nil
        lock.unlock()

        pending?.resume(with: result)
    }

    func cancel() {
        lock.lock()
        isCancelled = true
        let pending = isResumed ? nil : continuation
        isResumed = true
        continuation = nil
        let cancellable = cancellable
        lock.unlock()

        cancellable?.cancel()
        pending?.resume(throwing: CancellationError())
    }
}
