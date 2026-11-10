// Tests for the weighted lanes and adaptive pacing of RateGate, on a virtual clock.

import Foundation
import Testing
@testable import WalletKit

private func settle() async {
    for _ in 0 ..< 50 {
        await Task.yield()
    }

    try? await Task.sleep(for: .milliseconds(20))
}

private actor LaneLog {
    private(set) var order: [RequestLane] = []

    func record(_ lane: RequestLane) {
        order.append(lane)
    }
}

struct RateGateLaneTests {
    @Test func higherLanesAreAdmittedAheadOfBackfillByWeight() async throws {
        let clock = ManualClock()
        let gate = RateGate(clock: clock, maxCallsPerSecond: 10)
        let log = LaneLog()

        try await gate.acquire(lane: .polling)

        var tasks: [Task<Void, Error>] = []
        for lane in [RequestLane.backfill, .balances] {
            for _ in 0 ..< 10 {
                tasks.append(Task {
                    try await gate.acquire(lane: lane)
                    await log.record(lane)
                })
            }
        }

        await settle()

        for _ in 0 ..< 9 {
            clock.advance(by: .milliseconds(100))
            await settle()
        }

        let firstNine = await log.order
        #expect(firstNine.count == 9)
        #expect(firstNine.filter { $0 == .backfill }.count <= 2)
        #expect(firstNine.filter { $0 == .balances }.count >= 7)

        for task in tasks {
            task.cancel()
        }
    }

    @Test func aLoneBackfillLaneDrainsAtTheFullRate() async throws {
        let clock = ManualClock()
        let gate = RateGate(clock: clock, maxCallsPerSecond: 10)
        let log = LaneLog()

        try await gate.acquire(lane: .backfill)

        let tasks = (0 ..< 3).map { _ in
            Task {
                try await gate.acquire(lane: .backfill)
                await log.record(.backfill)
            }
        }

        for _ in 0 ..< 3 {
            clock.advance(by: .milliseconds(100))
            await settle()
        }

        #expect(await log.order.count == 3)

        for task in tasks {
            try await task.value
        }
    }

    @Test func aNewHighLaneWaiterOvertakesQueuedBackfill() async throws {
        let clock = ManualClock()
        let gate = RateGate(clock: clock, maxCallsPerSecond: 10)
        let log = LaneLog()

        try await gate.acquire(lane: .polling)

        let backfill = (0 ..< 5).map { _ in
            Task {
                try await gate.acquire(lane: .backfill)
                await log.record(.backfill)
            }
        }

        await settle()

        let interactive = Task {
            try await gate.acquire(lane: .interactive)
            await log.record(.interactive)
        }

        await settle()
        clock.advance(by: .milliseconds(100))
        await settle()

        #expect(await log.order == [.interactive])

        interactive.cancel()
        for task in backfill {
            task.cancel()
        }
    }

    @Test func aCooldownDelaysEveryLane() async throws {
        let clock = ManualClock()
        let gate = RateGate(clock: clock, maxCallsPerSecond: 10)
        let log = LaneLog()

        try await gate.acquire(lane: .polling)
        await gate.penalize(by: .seconds(5))

        let tasks = [RequestLane.interactive, .backfill].map { lane in
            Task {
                try await gate.acquire(lane: lane)
                await log.record(lane)
            }
        }

        clock.advance(by: .seconds(4))
        await settle()
        #expect(await log.order.isEmpty)

        clock.advance(by: .seconds(2))
        await settle()
        #expect(await log.order.count == 1)

        for task in tasks {
            task.cancel()
        }
    }

    @Test func cancellingAQueuedWaiterInALaneFreesItsSlot() async throws {
        let clock = ManualClock()
        let gate = RateGate(clock: clock, maxCallsPerSecond: 10)

        try await gate.acquire(lane: .polling)

        let cancelled = Task { try await gate.acquire(lane: .backfill) }
        let live = Task { try await gate.acquire(lane: .backfill) }

        await settle()
        cancelled.cancel()

        await #expect(throws: CancellationError.self) {
            try await cancelled.value
        }

        clock.advance(by: .milliseconds(100))
        await settle()
        try await live.value
    }
}

// MARK: - Adaptive pacing

struct RateGateAdaptiveTests {
    private func advance(_ clock: ManualClock, by duration: Duration) async {
        clock.advance(by: duration)
        await settle()
    }

    /// An adaptive gate that admitted `admissions` calls at t = 0 and then took a signal.
    private func pacedGate(clock: ManualClock, admissions: Int) async throws -> RateGate<ManualClock> {
        let gate = RateGate(clock: clock, maxCallsPerSecond: nil)

        for _ in 0 ..< admissions {
            try await gate.acquire()
        }

        await gate.penalize(by: .seconds(1))
        return gate
    }

    @Test func unpacedGateAdmitsEveryoneImmediately() async throws {
        let gate = RateGate(clock: ManualClock(), maxCallsPerSecond: nil)

        for _ in 0 ..< 20 {
            try await gate.acquire()
        }

        #expect(await gate.mode == .unpaced)
    }

    @Test func aQuotaSignalHalvesTheMeasuredRate() async throws {
        let gate = try await pacedGate(clock: ManualClock(), admissions: 50)

        #expect(await gate.mode == .paced)
        #expect(await gate.ceiling == 10)
        #expect(await gate.rate == 5)
    }

    @Test func aSparseSampleNeverGoesBelowTheFloor() async throws {
        let gate = try await pacedGate(clock: ManualClock(), admissions: 1)

        #expect(await gate.rate == 1)
        #expect(await gate.ceiling == 1)
    }

    @Test func repeatedSignalsOnlyHoldOrLowerTheRate() async throws {
        let clock = ManualClock()
        let gate = try await pacedGate(clock: clock, admissions: 50)

        await gate.penalize(by: .seconds(1)) // inside the cooldown: extends it only
        #expect(await gate.rate == 5)

        await advance(clock, by: .seconds(2))
        await gate.penalize(by: .seconds(1))
        #expect(await gate.rate == 2.5)
        #expect(await gate.ceiling == 5)

        await advance(clock, by: .seconds(2))
        await gate.penalize(by: .seconds(1))
        #expect(await gate.rate == 1.25)

        await advance(clock, by: .seconds(2))
        await gate.penalize(by: .seconds(1))
        #expect(await gate.rate == 1)
    }

    @Test func recoveryNeedsSuccessesNotIdleTime() async throws {
        let clock = ManualClock()
        let gate = try await pacedGate(clock: clock, admissions: 50)

        await advance(clock, by: .seconds(16))
        try await gate.acquire()
        #expect(await gate.rate == 5)

        for _ in 0 ..< 30 {
            await gate.recordSuccess()
        }

        await advance(clock, by: .seconds(16))
        try await gate.acquire()
        #expect(await gate.rate == 5.5)
    }

    @Test func aProbePassesOnlyWithSuccessesAndAnEmptyQueue() async throws {
        let clock = ManualClock()
        let gate = try await pacedGate(clock: clock, admissions: 1)

        await advance(clock, by: .seconds(31))
        try await gate.acquire()
        #expect(await gate.mode == .probing)

        // Idle time alone never passes a probe.
        await advance(clock, by: .seconds(600))
        try await gate.acquire()
        #expect(await gate.mode == .probing)

        // Admissions without successes don't either.
        for _ in 0 ..< 25 {
            await advance(clock, by: .seconds(1))
            try await gate.acquire()
        }

        #expect(await gate.mode == .probing)

        for _ in 0 ..< 20 {
            await gate.recordSuccess()
        }

        await advance(clock, by: .seconds(61))
        try await gate.acquire()
        #expect(await gate.mode == .unpaced)
    }

    @Test func aBacklogKeepsTheGateProbingEvenWhenTheCriteriaAreMet() async throws {
        let clock = ManualClock()
        let gate = try await pacedGate(clock: clock, admissions: 1)

        await advance(clock, by: .seconds(31))
        try await gate.acquire()
        #expect(await gate.mode == .probing)

        await advance(clock, by: .seconds(61))

        let first = Task { try await gate.acquire() }
        let second = Task { try await gate.acquire() }
        await settle()

        for _ in 0 ..< 20 {
            await gate.recordSuccess()
        }

        #expect(await gate.mode == .probing)

        await advance(clock, by: .seconds(1))
        try await first.value
        try await second.value
        await gate.recordSuccess()
        #expect(await gate.mode == .unpaced)
    }

    @Test func aSignalWhileProbingRestoresTheProvenRateAndDoublesTheQuietPeriod() async throws {
        let clock = ManualClock()
        let gate = try await pacedGate(clock: clock, admissions: 1)

        await advance(clock, by: .seconds(31))
        try await gate.acquire()
        #expect(await gate.mode == .probing)

        await advance(clock, by: .seconds(2))
        await gate.penalize(by: .seconds(1))

        #expect(await gate.mode == .paced)
        #expect(await gate.rate == 1)
        #expect(await gate.quietPeriod == .seconds(60))
    }

    @Test func aFixedRateGateNeverAdapts() async throws {
        let clock = ManualClock()
        let gate = RateGate(clock: clock, maxCallsPerSecond: 4)

        try await gate.acquire()
        await gate.penalize(by: .seconds(1))
        await gate.recordSuccess()

        #expect(await gate.mode == .fixed)
        #expect(await gate.rate == 4)
    }
}

struct RateGateReviewTests {
    @Test func cooldownWaitCountsOnlyTimeInsideTheCooldown() async throws {
        let clock = ManualClock()
        let gate = RateGate(clock: clock, maxCallsPerSecond: 0.1) // 10 s apart

        try await gate.acquire(lane: .polling)

        let waiter = Task { try await gate.acquire(lane: .backfill) }
        await settle()

        clock.advance(by: .seconds(8))
        await settle()
        await gate.penalize(by: .seconds(4)) // cooldown covers t = 8...12

        clock.advance(by: .seconds(4))
        await settle()
        try await waiter.value

        let stats = try #require(await gate.stats[.backfill])
        #expect(stats.totalWait == .seconds(12))
        #expect(stats.totalCooldownWait == .seconds(4))
    }

    @Test func theQuietPeriodStartsAfterTheLatestQuotaSignal() async throws {
        let clock = ManualClock()
        let gate = RateGate(clock: clock, maxCallsPerSecond: nil)

        try await gate.acquire()
        clock.advance(by: .seconds(100)) // long idle before the signal
        await gate.penalize(by: .seconds(1))

        clock.advance(by: .seconds(5))
        await settle()
        try await gate.acquire()
        #expect(await gate.mode == .paced)

        clock.advance(by: .seconds(31))
        await settle()
        try await gate.acquire()
        #expect(await gate.mode == .probing)
    }

    @Test func aFailedProbeRestartsTheDoubledQuietPeriod() async throws {
        let clock = ManualClock()
        let gate = RateGate(clock: clock, maxCallsPerSecond: nil)

        try await gate.acquire()
        await gate.penalize(by: .seconds(1))
        clock.advance(by: .seconds(40))
        await settle()
        try await gate.acquire()
        #expect(await gate.mode == .probing)

        clock.advance(by: .seconds(2))
        await settle()
        await gate.penalize(by: .seconds(1)) // probe fails: quiet period becomes 60 s

        clock.advance(by: .seconds(50))
        await settle()
        try await gate.acquire()
        #expect(await gate.mode == .paced)

        clock.advance(by: .seconds(15))
        await settle()
        try await gate.acquire()
        #expect(await gate.mode == .probing)
    }

    @Test func anOversizedProviderDelayIsClampedBeforeConversion() {
        let signal = QuotaSignal.detect(
            code: -32005,
            message: "limit",
            data: ["backoff_seconds": 1e300, "allowed_rps": 5.0]
        )

        #expect(signal?.retryAfter == .seconds(60))
    }
}
