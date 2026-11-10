import Foundation

/// Paces callers of a shared instance, coordinating every concurrent caller
/// against the same deadline instead of letting each discover a rate limit
/// independently. Callers queue per ``RequestLane`` and are admitted by
/// weighted fair share (stride scheduling), so a saturated low lane can't
/// delay a higher one. A single scheduled wake — not independent per-caller
/// sleeps — lets `penalize(by:)` push back callers that are already queued.
///
/// A gate with a confirmed rate (`maxCallsPerSecond != nil`) paces at that
/// rate and only takes cooldowns. An adaptive gate (`nil`) admits freely
/// until a quota signal, then paces below the rate that failed and recovers
/// only from successful traffic (see ``Mode``).
///
/// Generic over `Clock` so tests can inject a virtual clock instead of
/// waiting on real time; production uses `RateGate<ContinuousClock>`.
actor RateGate<C: Clock> where C.Duration == Duration {
    enum Mode: Equatable {
        /// Confirmed rate; never adapts.
        case fixed
        /// Adaptive, no quota signal seen (or recovered): no spacing.
        case unpaced
        /// Adaptive, spaced below the rate that triggered a quota signal.
        case paced
        /// Adaptive trial of unpaced admission, bounded to twice the proven rate.
        case probing
    }

    private struct Waiter {
        let id: UUID
        let enqueued: C.Instant
        let continuation: CheckedContinuation<Void, Error>
    }

    private let clock: C
    private let fixedInterval: Duration?
    private var queues: [RequestLane: [Waiter]] = [:]
    private var passes: [RequestLane: Double] = [:]
    private var virtualTime = 0.0
    private var wakeTask: Task<Void, Never>?

    // Not `private`: tests read these directly instead of racing an observer.
    var nextAllowedTime: C.Instant
    private(set) var mode: Mode
    private(set) var rate: Double
    private(set) var ceiling: Double
    private(set) var quietPeriod = RateGateTuning.initialQuiet
    /// Admissions per lane and successes reported since creation, for logging and tests.
    private(set) var admittedByLane: [RequestLane: Int] = [:]
    private(set) var stats: [RequestLane: LaneAdmissionStats] = [:]
    private(set) var recordedSuccesses = 0

    /// Whether a server-requested cooldown is still running.
    var cooldownIsActive: Bool {
        clock.now < cooldownUntil
    }

    private var cooldownUntil: C.Instant
    /// Recent cooldown periods, for attributing waits to cooldowns rather than queueing.
    private var cooldownWindows: [(start: C.Instant, end: C.Instant)] = []
    private var preProbeRate: Double
    private var admissions: [C.Instant] = []
    private var successesInInterval = 0
    private var successesInProbe = 0
    private var intervalStart: C.Instant
    private var probeStart: C.Instant
    private var lastBacklog: C.Instant

    init(clock: C, maxCallsPerSecond: Double?) {
        precondition(maxCallsPerSecond.map { $0.isFinite && $0 > 0 } ?? true)
        self.clock = clock
        fixedInterval = maxCallsPerSecond.map { .seconds(1 / $0) }
        mode = maxCallsPerSecond == nil ? .unpaced : .fixed
        rate = maxCallsPerSecond ?? .infinity
        ceiling = rate
        preProbeRate = rate
        nextAllowedTime = clock.now
        cooldownUntil = clock.now
        intervalStart = clock.now
        probeStart = clock.now
        lastBacklog = clock.now
    }

    deinit {
        wakeTask?.cancel()
    }

    /// Suspends until this caller's slot arrives. Throws `CancellationError`
    /// if the calling `Task` is cancelled while still queued.
    func acquire(lane: RequestLane = .interactive) async throws {
        try Task.checkCancellation()
        evaluate()

        if waiting == 0, clock.now >= nextAllowedTime {
            admit(lane: lane)
            return
        }

        lastBacklog = clock.now
        let id = UUID()

        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                enqueue(Waiter(id: id, enqueued: clock.now, continuation: continuation), lane: lane)
                rescheduleWake()
            }
        } onCancel: {
            Task { await self.cancelWaiter(id) }
        }
    }

    /// A quota signal from the origin. `extra` is a cooldown *duration from
    /// now* (e.g. a server's `Retry-After`), not an increment to stack onto
    /// the existing deadline — two overlapping `Retry-After: 10` responses
    /// must both resolve to "wait until ~10s from now", not compound to 20s.
    /// An adaptive gate also lowers its rate, once per cooldown.
    func penalize(by extra: Duration) {
        let now = clock.now
        let isNewSignal = now >= cooldownUntil

        cooldownUntil = max(cooldownUntil, now.advanced(by: extra))
        nextAllowedTime = max(nextAllowedTime, cooldownUntil)
        recordCooldown(from: now, isNew: isNewSignal)

        // The quiet period that gates a probe starts when the cooldown ends, not earlier.
        lastBacklog = max(lastBacklog, cooldownUntil)

        if isNewSignal {
            adaptToQuotaSignal()
        }

        rescheduleWake()
    }

    /// One completed, quota-free response. Only successes advance recovery.
    func recordSuccess() {
        recordedSuccesses += 1

        switch mode {
        case .paced: successesInInterval += 1
        case .probing: successesInProbe += 1
        case .fixed, .unpaced: return
        }

        evaluate()
        rescheduleWake()
    }

    // MARK: - Scheduling

    private var waiting: Int {
        queues.values.reduce(0) { $0 + $1.count }
    }

    private var interval: Duration {
        switch mode {
        case .fixed: fixedInterval ?? .zero
        case .unpaced: .zero
        case .paced: .seconds(1 / rate)
        case .probing: .seconds(1 / (2 * preProbeRate))
        }
    }

    private func enqueue(_ waiter: Waiter, lane: RequestLane) {
        if queues[lane, default: []].isEmpty {
            passes[lane] = max(passes[lane] ?? 0, virtualTime)
        }

        queues[lane, default: []].append(waiter)
    }

    /// The non-empty lane with the smallest pass; ties go to the higher weight.
    private func nextLane() -> RequestLane? {
        queues
            .filter { !$0.value.isEmpty }
            .keys
            .min { lhs, rhs in
                let (left, right) = (passes[lhs] ?? 0, passes[rhs] ?? 0)
                return left == right ? lhs.weight > rhs.weight : left < right
            }
    }

    private func recordCooldown(from now: C.Instant, isNew: Bool) {
        if isNew || cooldownWindows.isEmpty {
            cooldownWindows.append((start: now, end: cooldownUntil))
            cooldownWindows.removeFirst(max(0, cooldownWindows.count - 32))
        } else {
            cooldownWindows[cooldownWindows.count - 1].end = cooldownUntil
        }
    }

    private func recordWait(lane: RequestLane, since enqueued: C.Instant) {
        let now = clock.now
        let wait = enqueued.duration(to: now)
        let cooldown = cooldownWindows.reduce(Duration.zero) { total, window in
            let start = max(window.start, enqueued)
            let end = min(window.end, now)
            return start < end ? total + start.duration(to: end) : total
        }

        var entry = stats[lane] ?? LaneAdmissionStats()
        entry.totalWait += wait
        entry.maxWait = max(entry.maxWait, wait)
        entry.totalCooldownWait += cooldown
        stats[lane] = entry
    }

    private func admit(lane: RequestLane) {
        let now = clock.now
        admittedByLane[lane, default: 0] += 1
        stats[lane, default: LaneAdmissionStats()].count += 1

        if queues[lane, default: []].isEmpty {
            passes[lane] = max(passes[lane] ?? 0, virtualTime)
        }

        virtualTime = passes[lane] ?? virtualTime
        passes[lane] = virtualTime + 1 / lane.weight
        nextAllowedTime = max(cooldownUntil, now.advanced(by: interval))

        admissions.append(now)
        admissions.removeAll { $0.duration(to: now) > RateGateTuning.measureWindow }
    }

    private func rescheduleWake() {
        wakeTask?.cancel()

        guard waiting > 0 else {
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
        evaluate()

        guard let lane = nextLane(), clock.now >= nextAllowedTime else {
            rescheduleWake()
            return
        }

        admit(lane: lane)

        if let waiter = queues[lane]?.removeFirst() {
            recordWait(lane: lane, since: waiter.enqueued)
            waiter.continuation.resume()
        }

        if waiting > 0 {
            lastBacklog = clock.now
        }

        rescheduleWake()
    }

    private func cancelWaiter(_ id: UUID) {
        for (lane, queue) in queues {
            guard let index = queue.firstIndex(where: { $0.id == id }) else {
                continue
            }

            queues[lane]?.remove(at: index).continuation.resume(throwing: CancellationError())
            rescheduleWake()
            return
        }
    }

    // MARK: - Adaptation

    private var cap: Double {
        max(RateGateTuning.floor, RateGateTuning.capFactor * ceiling)
    }

    private func clamped(_ value: Double) -> Double {
        max(RateGateTuning.floor, min(value, cap))
    }

    private func adaptToQuotaSignal() {
        successesInInterval = 0
        successesInProbe = 0
        intervalStart = clock.now

        switch mode {
        case .fixed:
            return

        case .unpaced:
            let now = clock.now
            let recent = admissions.filter { $0.duration(to: now) <= RateGateTuning.measureWindow }.count
            let measured = Double(recent) / RateGateTuning.measureWindow.timeIntervalValue
            ceiling = max(RateGateTuning.floor, measured)
            rate = clamped(measured / 2)
            mode = .paced

        case .paced:
            ceiling = min(ceiling, rate)
            rate = clamped(rate / 2)

        case .probing:
            rate = preProbeRate
            quietPeriod = min(quietPeriod * 2, RateGateTuning.maxQuiet)
            mode = .paced
        }
    }

    /// Time-driven transitions, evaluated lazily at every gate event.
    private func evaluate() {
        let now = clock.now

        switch mode {
        case .fixed, .unpaced:
            return

        case .paced:
            if intervalStart.duration(to: now) >= RateGateTuning.growthInterval {
                if Double(successesInInterval) >= max(3, rate * 5) {
                    rate = clamped(rate * RateGateTuning.growthFactor)
                }

                successesInInterval = 0
                intervalStart = now
            }

            if waiting == 0, lastBacklog.duration(to: now) >= quietPeriod {
                preProbeRate = rate
                probeStart = now
                successesInProbe = 0
                mode = .probing
            }

        case .probing:
            if waiting == 0,
               probeStart.duration(to: now) >= RateGateTuning.probeMinimumDuration,
               successesInProbe >= RateGateTuning.probeMinimumSuccesses {
                quietPeriod = RateGateTuning.initialQuiet
                mode = .unpaced
            }
        }
    }
}

private enum RateGateTuning {
    static let floor = 1.0
    static let capFactor = 0.8
    static let measureWindow = Duration.seconds(5)
    static let growthInterval = Duration.seconds(15)
    static let growthFactor = 1.1
    static let initialQuiet = Duration.seconds(30)
    static let maxQuiet = Duration.seconds(600)
    static let probeMinimumDuration = Duration.seconds(60)
    static let probeMinimumSuccesses = 20
}
