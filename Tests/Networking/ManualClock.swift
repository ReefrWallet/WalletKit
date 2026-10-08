// A virtual `Clock` for `RateGate` tests — `advance(by:)` moves time forward
// deterministically and wakes any sleepers whose deadline has passed,
// instead of tests waiting on real wall-clock delays.

import Foundation

final class ManualClock: Clock, @unchecked Sendable {
    struct Instant: InstantProtocol {
        fileprivate var offset: Duration

        func advanced(by duration: Duration) -> Instant {
            Instant(offset: offset + duration)
        }

        func duration(to other: Instant) -> Duration {
            other.offset - offset
        }

        static func < (lhs: Instant, rhs: Instant) -> Bool {
            lhs.offset < rhs.offset
        }
    }

    private struct Sleeper {
        let deadline: Instant
        let continuation: CheckedContinuation<Void, Never>
    }

    private let lock = NSLock()
    private var currentInstant = Instant(offset: .zero)
    private var sleepers: [Sleeper] = []

    var now: Instant {
        lock.withLock { currentInstant }
    }

    var minimumResolution: Duration { .zero }

    func sleep(until deadline: Instant, tolerance: Duration?) async throws {
        await withCheckedContinuation { continuation in
            lock.lock()

            if deadline <= currentInstant {
                lock.unlock()
                continuation.resume()
                return
            }

            sleepers.append(Sleeper(deadline: deadline, continuation: continuation))
            lock.unlock()
        }
    }

    /// Advances the clock and resumes every sleeper whose deadline is now due.
    func advance(by duration: Duration) {
        lock.lock()
        currentInstant = currentInstant.advanced(by: duration)
        let due = sleepers.filter { $0.deadline <= currentInstant }
        sleepers.removeAll { $0.deadline <= currentInstant }
        lock.unlock()

        for sleeper in due {
            sleeper.continuation.resume()
        }
    }
}
