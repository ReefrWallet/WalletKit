import Darwin
import Foundation

extension Process {
    /// Stops a local-node child process without risking an unbounded wait.
    ///
    /// `terminate()` sends SIGTERM, which a node may handle slowly or not at
    /// all (observed with `sui start`); a bare `waitUntilExit()` after it
    /// then blocks the test forever and trips the suite's time limit long
    /// after the test body finished. Escalates to SIGKILL after `grace`, then
    /// waits at most `grace` more.
    func terminateAndWait(grace: TimeInterval = 5) {
        guard isRunning else {
            return
        }

        terminate()

        let deadline = Date().addingTimeInterval(grace)

        while isRunning, Date() < deadline {
            usleep(50_000)
        }

        guard isRunning else {
            return
        }

        kill(processIdentifier, SIGKILL)

        // Bounded: `waitUntilExit()` can block forever if Foundation misses
        // the exit notification under load.
        let killDeadline = Date().addingTimeInterval(grace)

        while isRunning, Date() < killDeadline, kill(processIdentifier, 0) == 0 {
            usleep(50_000)
        }
    }
}
