import Foundation

/// Admission statistics of one lane at one origin, for diagnostics.
public struct LaneAdmissionStats: Sendable, Equatable {
    /// Admissions, including those that didn't wait.
    public var count = 0
    /// Sum and maximum of the time between a request queuing and its admission.
    public var totalWait = Duration.zero
    public var maxWait = Duration.zero
    /// Part of `totalWait` spent inside a server-requested cooldown.
    public var totalCooldownWait = Duration.zero

    public init() {}

    /// Mean wait excluding cooldowns.
    public var meanWaitExcludingCooldown: Duration {
        count == 0 ? .zero : (totalWait - totalCooldownWait) / count
    }
}

/// A priority class for requests sharing one origin's rate budget. Each lane
/// queues separately in `RateGate` and is served by weighted fair share, so
/// a long backfill can't starve balance, staking or approval requests, and
/// still makes progress itself.
///
/// The lane is read from ``current`` when a request is issued. Work with no
/// lane set is ``interactive``. Unstructured `Task`s inherit the task-local,
/// so each long-lived service task sets its own lane at its root.
public enum RequestLane: String, CaseIterable, Sendable {
    case approvals
    case backfill
    case balances
    case interactive
    case polling

    /// The lane of the calling task.
    @TaskLocal public static var current: RequestLane = .interactive

    /// Relative share of an origin's budget while several lanes have queued requests.
    var weight: Double {
        switch self {
        case .approvals: 4
        case .backfill: 1
        case .balances: 8
        case .interactive: 16
        case .polling: 8
        }
    }
}
