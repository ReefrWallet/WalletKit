// Tests for Sources/WalletKit/Networking/RateGate.swift. Uses `ManualClock`
// so timing is deterministic — `advance(by:)` moves the clock forward and
// wakes due sleepers synchronously; tests then `settle()` (a short `Task
// .yield()` loop) to let the resulting actor hops/continuation resumes
// actually run before asserting.

import Foundation
import Testing
@testable import WalletKit

private func settle() async {
    for _ in 0 ..< 50 {
        await Task.yield()
    }

    // Yields alone can be starved when the whole suite runs in parallel.
    try? await Task.sleep(for: .milliseconds(20))
}

struct RateGateTests {
    @Test func acquireAdmitsTheFirstCallerImmediately() async throws {
        let clock = ManualClock()
        let gate = RateGate(clock: clock, maxCallsPerSecond: 2)

        try await gate.acquire()
    }

    @Test func acquireSpacesCallersByTheConfiguredInterval() async throws {
        let clock = ManualClock()
        let gate = RateGate(clock: clock, maxCallsPerSecond: 2) // 500ms apart
        let admitted = AdmittedLog()

        let tasks = (0 ..< 3).map { index in
            Task {
                try await gate.acquire()
                await admitted.record(index)
            }
        }

        await settle()
        #expect(await admitted.count == 1)

        clock.advance(by: .milliseconds(500))
        await settle()
        #expect(await admitted.count == 2)

        clock.advance(by: .milliseconds(500))
        await settle()
        #expect(await admitted.count == 3)

        for task in tasks {
            try await task.value
        }

        // Enqueue order among concurrently-*launched* Tasks isn't itself
        // guaranteed (only FIFO order *once enqueued* is) — the meaningful
        // assertion is that all three were admitted, one per interval.
        #expect(Set(await admitted.order) == [0, 1, 2])
    }

    @Test func cancellingAQueuedWaiterThrowsCancellationErrorAndFreesItsSlot() async throws {
        let clock = ManualClock()
        let gate = RateGate(clock: clock, maxCallsPerSecond: 2) // 500ms apart
        let admitted = AdmittedLog()

        // First caller is admitted immediately (deadline == now).
        try await gate.acquire()

        let cancelledTask = Task {
            try await gate.acquire()
        }

        let secondTask = Task {
            try await gate.acquire()
            await admitted.record(1)
        }

        await settle()
        cancelledTask.cancel()

        await #expect(throws: CancellationError.self) {
            try await cancelledTask.value
        }

        // The cancelled waiter must not occupy the next slot — `secondTask`
        // should still be admitted exactly one `minimumInterval` after the
        // first caller, not delayed by the cancelled one ahead of it.
        clock.advance(by: .milliseconds(500))
        await settle()

        try await secondTask.value
        #expect(await admitted.count == 1)
    }

    @Test func penalizeMovesBackAlreadyQueuedWaitersNotJustFutureOnes() async throws {
        let clock = ManualClock()
        let gate = RateGate(clock: clock, maxCallsPerSecond: 2) // 500ms apart
        let admitted = AdmittedLog()

        try await gate.acquire() // admitted immediately, sets nextAllowedTime = +500ms

        let queuedTask = Task {
            try await gate.acquire()
            await admitted.record(1)
        }

        await settle()
        await gate.penalize(by: .seconds(5))

        // Without the penalty this waiter would be due now; it must not be
        // admitted yet, since it was already queued when the penalty hit.
        clock.advance(by: .milliseconds(500))
        await settle()
        #expect(await admitted.order.isEmpty)

        // Now past the penalty's deadline (~5s from when it was applied).
        clock.advance(by: .seconds(5))
        await settle()
        #expect(await admitted.count == 1)

        try await queuedTask.value
    }

    @Test func overlappingPenaltiesDoNotCompound() async throws {
        let clock = ManualClock()
        let gate = RateGate(clock: clock, maxCallsPerSecond: 2)
        let admitted = AdmittedLog()

        try await gate.acquire() // admitted immediately

        let queuedTask = Task {
            try await gate.acquire()
            await admitted.record(1)
        }

        await settle()
        await gate.penalize(by: .seconds(10))
        await gate.penalize(by: .seconds(10))

        // If the two penalties wrongly compounded, this wouldn't be enough.
        clock.advance(by: .seconds(11))
        await settle()
        #expect(await admitted.count == 1)

        try await queuedTask.value
    }
}

private actor AdmittedLog {
    private(set) var order: [Int] = []

    var count: Int { order.count }

    func record(_ index: Int) {
        order.append(index)
    }
}
