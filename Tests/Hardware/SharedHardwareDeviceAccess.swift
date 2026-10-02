// `HardwareDeviceManager.connect(_:delegate:)` claims exclusive USB access to
// the single physical Trezor these integration tests share. Swift Testing
// parallelizes across suites by default — same as the cross-suite race
// StubURLProtocol.swift's note describes — so two tests connecting to the
// device concurrently make each other see `.deviceDisconnected` rather than
// both succeeding. `.serialized` on an individual `@Suite` doesn't help: it
// only serializes tests within that suite, not across
// HardwareDeviceTests/HardwareDeviceManagerTests/EthereumTrezorSignerTests.
//
// This is a real async mutex (not a bare `actor`, whose methods are
// reentrant at their own `await` points) — the fast path never suspends, and
// the slow path parks the caller on a continuation until `unlock()` wakes it.

private actor HardwareDeviceLock {
    static let shared = HardwareDeviceLock()

    private var isLocked = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func lock() async {
        if !isLocked {
            isLocked = true
            return
        }

        await withCheckedContinuation { waiters.append($0) }
    }

    func unlock() {
        if waiters.isEmpty {
            isLocked = false
        } else {
            waiters.removeFirst().resume()
        }
    }
}

func withExclusiveHardwareAccess<T: Sendable>(_ body: () async throws -> T) async throws -> T {
    await HardwareDeviceLock.shared.lock()
    do {
        let result = try await body()
        await HardwareDeviceLock.shared.unlock()
        return result
    } catch {
        await HardwareDeviceLock.shared.unlock()
        throw error
    }
}
