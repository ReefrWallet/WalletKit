/// A FIFO async mutex.
actor AsyncGate {
    private var isBusy = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func acquire() async {
        guard isBusy else {
            isBusy = true
            return
        }

        await withCheckedContinuation { waiters.append($0) }
    }

    func release() {
        guard waiters.isEmpty else {
            waiters.removeFirst().resume()
            return
        }

        isBusy = false
    }
}

private let nodeStartupGate = AsyncGate()

/// Runs `body` while no other local node in this process is starting.
///
/// Nodes pick free ports and then bind them, and some (Solana, Sui) bind
/// more ports internally. Suites starting nodes in parallel can race for the
/// same port in between, so startups take turns; running nodes don't.
func withNodeStartupLock<T>(_ body: () async throws -> T) async throws -> T {
    await nodeStartupGate.acquire()

    do {
        let result = try await body()
        await nodeStartupGate.release()
        return result
    } catch {
        await nodeStartupGate.release()
        throw error
    }
}
