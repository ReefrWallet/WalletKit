import Foundation
import Moya

/// `async`/`await` entry points for `MoyaProvider`, cancellation-aware: if
/// the calling `Task` is cancelled, the underlying Moya `Cancellable` is
/// cancelled too, rather than left running unobserved.
public extension MoyaProvider {
    func requestResponse(_ target: Target) async throws -> Response {
        let box = CancellableBox()

        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                let cancellable = self.request(target) { result in
                    switch result {
                    case let .success(response):
                        continuation.resume(returning: response)
                    case let .failure(error):
                        continuation.resume(throwing: error)
                    }
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
/// context, possibly before the `Cancellable` even exists yet).
private final class CancellableBox: @unchecked Sendable {
    private let lock = NSLock()
    private var cancellable: Moya.Cancellable?
    private var isCancelled = false

    func set(_ cancellable: Moya.Cancellable) {
        lock.lock()
        defer { lock.unlock() }

        if isCancelled {
            cancellable.cancel()
        } else {
            self.cancellable = cancellable
        }
    }

    func cancel() {
        lock.lock()
        defer { lock.unlock() }

        isCancelled = true
        cancellable?.cancel()
    }
}
