import Foundation

/// Paces callers of a shared instance to a fixed rate, coordinating every
/// concurrent caller against the same deadline instead of letting each
/// discover a rate limit independently. A FIFO waiter queue with a single
/// scheduled wake — not independent per-caller sleeps — so `penalize(by:)`
/// can push back callers that are already queued, not just ones that
/// enqueue afterward.
///
/// Generic over `Clock` so tests can inject a virtual clock instead of
/// waiting on real time; production uses `RateGate<ContinuousClock>`.
actor RateGate<C: Clock> where C.Duration == Duration {
    private struct Waiter {
        let id: UUID
        let continuation: CheckedContinuation<Void, Error>
    }

    private let clock: C
    private let minimumInterval: Duration
    private var waiters: [Waiter] = []
    private var wakeTask: Task<Void, Never>?

    // Not `private`: `RateLimitRetryPolicyTests` reads this directly to
    // confirm `penalize(by:)` ran, instead of racing an observer `Task`
    // against real wall-clock timing (unreliable — Alamofire's own
    // retry-delay already consumes the same duration the penalty does, so
    // nothing "extra" is observable from outside by the time a request
    // making its own retry finishes).
    var nextAllowedTime: C.Instant

    init(clock: C, maxCallsPerSecond: Double) {
        precondition(maxCallsPerSecond.isFinite && maxCallsPerSecond > 0)
        self.clock = clock
        minimumInterval = .seconds(1 / maxCallsPerSecond)
        nextAllowedTime = clock.now
    }

    deinit {
        wakeTask?.cancel()
    }

    /// Suspends until this caller's slot arrives. Throws `CancellationError`
    /// if the calling `Task` is cancelled while still queued.
    func acquire() async throws {
        let id = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                waiters.append(Waiter(id: id, continuation: continuation))
                rescheduleWake()
            }
        } onCancel: {
            Task { await self.cancelWaiter(id) }
        }
    }

    /// `extra` is a cooldown *duration from now* (e.g. a server's
    /// `Retry-After`), not an increment to stack onto the existing
    /// deadline — two overlapping `Retry-After: 10` responses must both
    /// resolve to "wait until ~10s from now", not compound to 20s. Rate
    /// spacing (`minimumInterval` between admissions) and a server-provided
    /// cooldown are conceptually different and must not be composed
    /// additively.
    func penalize(by extra: Duration) {
        nextAllowedTime = max(nextAllowedTime, clock.now.advanced(by: extra))
        rescheduleWake()
    }

    private func rescheduleWake() {
        wakeTask?.cancel()

        guard !waiters.isEmpty else {
            wakeTask = nil
            return
        }

        let deadline = nextAllowedTime
        wakeTask = Task {
            try? await clock.sleep(until: deadline, tolerance: nil)

            guard !Task.isCancelled else {
                return
            }

            admitHeadIfDue()
        }
    }

    private func admitHeadIfDue() {
        guard !waiters.isEmpty, clock.now >= nextAllowedTime else {
            rescheduleWake()
            return
        }

        let waiter = waiters.removeFirst()
        nextAllowedTime = clock.now.advanced(by: minimumInterval)
        waiter.continuation.resume()
        rescheduleWake()
    }

    private func cancelWaiter(_ id: UUID) {
        guard let index = waiters.firstIndex(where: { $0.id == id }) else {
            return
        }

        waiters.remove(at: index).continuation.resume(throwing: CancellationError())
        rescheduleWake()
    }
}
