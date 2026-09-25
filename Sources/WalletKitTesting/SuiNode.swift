import Darwin
import Foundation
import GRPCCore
import GRPCNIOTransportHTTP2Posix

import WalletKit
import WalletKitGRPC

/// An error raised when the local Sui network cannot be started or queried.
public struct SuiLaunchError: Error, CustomStringConvertible {
    /// A description of the failed local-node operation.
    public let description: String
}

/// Binds two distinct ephemeral TCP ports via the kernel (port 0) and reads
/// back what it assigned, so concurrently-running tests each get their own
/// `sui start` instance instead of racing over the hardcoded defaults —
/// Swift Testing parallelizes across suites by default, and a second `sui
/// start` that loses the port race still passes `waitUntilReady()` (it just
/// polls the port for a checkpoint height, not that it owns the process
/// bound there), silently attaching to the first test's network and
/// corrupting its wallet balances. Both sockets are kept open until both
/// ports are chosen so the two allocations can't collide with each other.
private func freeTCPPorts(_ count: Int) throws -> [UInt16] {
    var fds: [Int32] = []
    defer { fds.forEach { close($0) } }

    var ports: [UInt16] = []

    for _ in 0..<count {
        let fd = socket(AF_INET, SOCK_STREAM, 0)

        guard fd >= 0 else {
            throw SuiLaunchError(description: "socket() failed while allocating a free port")
        }

        fds.append(fd)

        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_addr.s_addr = INADDR_ANY
        addr.sin_port = 0

        let bindResult = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }

        guard bindResult == 0 else {
            throw SuiLaunchError(description: "bind() failed while allocating a free port")
        }

        var len = socklen_t(MemoryLayout<sockaddr_in>.size)

        let getResult = withUnsafeMutablePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                getsockname(fd, $0, &len)
            }
        }

        guard getResult == 0 else {
            throw SuiLaunchError(description: "getsockname() failed while allocating a free port")
        }

        ports.append(UInt16(bigEndian: addr.sin_port))
    }

    return ports
}

/// Serializes `SuiNode`'s startup burst (genesis through the first
/// checkpoint) across the whole test process.
///
/// Both `SuiLocalnetTests` and `SuiTransactionBuilderTests` spin up their
/// own full local `sui` validator, and Swift Testing parallelizes across
/// suites by default — `.serialized` on a `@Suite` only orders that
/// suite's own tests, it doesn't stop a *different* suite's tests from
/// running at the same time. Several concurrent `sui start` processes
/// mid-genesis compete for CPU badly enough to push an otherwise-fast test
/// past its test time limit, so this makes sure at most one node is
/// starting up at a time, regardless of which suite started it. Only the
/// startup burst is gated, not each node's whole lifetime: once a node is
/// ready its steady-state cost is low, and gating the full lifetime would
/// serialize every test end to end, queueing later ones past their own
/// time limit instead.
private actor SuiNodeGate {
    static let shared = SuiNodeGate()

    private var isBusy = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    public func acquire() async {
        guard isBusy else {
            isBusy = true
            return
        }

        await withCheckedContinuation { waiters.append($0) }
    }

    public func release() {
        guard waiters.isEmpty else {
            waiters.removeFirst().resume()
            return
        }

        isBusy = false
    }
}

public final class SuiNode {
    private static let localnetTimeout: Duration = .seconds(10)

    /// The local full node's gRPC port.
    public let rpcPort: UInt16
    private let faucetPort: UInt16
    private let process: Process
    private let workingDirectory: URL
    private let logHandle: FileHandle

    private init(process: Process, rpcPort: UInt16, faucetPort: UInt16, workingDirectory: URL, logHandle: FileHandle) {
        self.process = process
        self.rpcPort = rpcPort
        self.faucetPort = faucetPort
        self.workingDirectory = workingDirectory
        self.logHandle = logHandle
    }

    /// Launches a fresh local Sui network via `mise x sui -- sui start
    /// --force-regenesis --with-faucet`, and waits until it's actually
    /// producing checkpoints.
    ///
    /// - Parameters:
    ///   - rpcPort: Pass an explicit port to pin it; otherwise a free one is
    ///     allocated per call so concurrently-running tests don't race over
    ///     the same `sui` instance.
    ///   - faucetPort: Same as `rpcPort`, for the faucet's HTTP listener.
    /// - Throws: ``SuiLaunchError`` if `mise`/`sui` can't be found/run, or
    ///   if the node never becomes ready within 10 seconds.
    public static func start(rpcPort: UInt16? = nil, faucetPort: UInt16? = nil) async throws -> SuiNode {
        let allocatedPorts = try freeTCPPorts(2)
        let rpcPort = rpcPort ?? allocatedPorts[0]
        let faucetPort = faucetPort ?? allocatedPorts[1]

        let repoRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent() // Blockchains/
            .deletingLastPathComponent() // Tests/
            .deletingLastPathComponent() // WalletKit/

        guard let misePath = MiseTool.path else {
            throw SuiLaunchError(
                description: "mise was not found in PATH or the host user's .local/bin directory"
            )
        }

        let suiBinaryPath = try resolveSuiBinaryPath(misePath: misePath, repoRoot: repoRoot)

        let workingDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("sui-localnet-\(UUID().uuidString)")

        try FileManager.default.createDirectory(at: workingDirectory, withIntermediateDirectories: true)

        let logURL = workingDirectory.appendingPathComponent("sui.log")
        FileManager.default.createFile(atPath: logURL.path, contents: nil)
        let logHandle = try FileHandle(forWritingTo: logURL)

        let process = Process()
        process.executableURL = URL(fileURLWithPath: suiBinaryPath)
        process.arguments = [
            "start", "--force-regenesis",
            "--with-faucet=127.0.0.1:\(faucetPort)",
            "--fullnode-rpc-port", String(rpcPort),
            "--committee-size", "1",
            "-q"
        ]

        // `sui start --force-regenesis` always writes under
        // `$HOME/.sui/sui_config` — overriding HOME for just this process
        // sandboxes that without touching the real `~/.sui`.
        process.environment = ["HOME": workingDirectory.path]
        process.standardOutput = logHandle
        process.standardError = logHandle

        // Only the startup burst (genesis + first checkpoints, until
        // `waitUntilReady()` returns) is gated — that's the heavy, bursty
        // part. Once a node is up, its steady-state CPU cost is low enough
        // that letting it run alongside other already-started nodes doesn't
        // reintroduce the contention `SuiNodeGate` exists to avoid, and
        // gating the whole lifetime would serialize all six tests end to
        // end, queueing the last one past its own time limit.
        await SuiNodeGate.shared.acquire()
        defer { Task { await SuiNodeGate.shared.release() } }

        do {
            try process.run()
        } catch {
            throw SuiLaunchError(description: "failed to launch \(suiBinaryPath): \(error.localizedDescription)")
        }

        let node = SuiNode(
            process: process,
            rpcPort: rpcPort,
            faucetPort: faucetPort,
            workingDirectory: workingDirectory,
            logHandle: logHandle
        )

        try await node.waitUntilReady()
        return node
    }

    /// Resolves the pinned `sui` binary's absolute path via `mise which`,
    /// anchored to this repo's `mise.toml` (`-C repoRoot`) so the pinned
    /// `testnet-v1.77.2` is used even when another `sui` version is also
    /// installed. `mise x sui -- true` first, to trigger mise's own
    /// auto-install on first use — same as `EthereumNode`'s `mise x foundry`.
    private static func resolveSuiBinaryPath(misePath: String, repoRoot: URL) throws -> String {
        func run(_ arguments: [String]) throws -> String {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: misePath)
            process.arguments = arguments
            process.environment = MiseTool.processEnvironment

            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = Pipe()

            try process.run()
            process.waitUntilExit()

            guard process.terminationStatus == 0 else {
                throw SuiLaunchError(description: "\(misePath) \(arguments.joined(separator: " ")) failed")
            }

            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            return String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        }

        _ = try run(["-C", repoRoot.path, "x", "sui", "--", "true"])
        return try run(["-C", repoRoot.path, "which", "sui"])
    }

    /// Stops the local network and removes its temporary files.
    public func stop() {
        process.terminate()
        process.waitUntilExit()
        try? logHandle.close()
        try? FileManager.default.removeItem(at: workingDirectory)
    }

    deinit {
        if process.isRunning {
            process.terminate()
        }

        try? FileManager.default.removeItem(at: workingDirectory)
    }

    private func client() -> SuiGRPCClient {
        SuiGRPCClient(host: "127.0.0.1", port: Int(rpcPort), useTLS: false)
    }

    /// `CallOptions.defaults` leaves `timeout` at `nil` — a stalled call
    /// would hang forever, and the bounded `while` loops below (each with
    /// its own deadline) can't rescue that: `try?` only catches a *thrown*
    /// error, it doesn't cancel a call that never returns.
    private static var callOptions: GRPCCore.CallOptions {
        var options = GRPCCore.CallOptions.defaults
        options.timeout = localnetTimeout
        return options
    }

    private func waitUntilReady() async throws {
        let deadline = ContinuousClock.now.advanced(by: Self.localnetTimeout)

        while ContinuousClock.now < deadline {
            if let height = try? await checkpointHeight(), height > 0 {
                return
            }
            try? await Task.sleep(for: .milliseconds(200))
        }

        let log = (try? String(contentsOf: workingDirectory.appendingPathComponent("sui.log"), encoding: .utf8))
            ?? "(no log)"

        throw SuiLaunchError(description: "sui never became ready within 10s. Log tail:\n\(log.suffix(2000))")
    }

    private func checkpointHeight() async throws -> UInt64 {
        try await withLedgerServiceClient { ledger in
            let response = try await ledger.getServiceInfo(
                request: ClientRequest(message: Sui_Rpc_V2_GetServiceInfoRequest()),
                options: Self.callOptions
            )

            return response.checkpointHeight
        }
    }

    /// Requests SUI from the local faucet for `address`, then waits for one
    /// more owned SUI coin object than the address held before the request.
    /// This sidesteps the faucet response body's version-dependent shape
    /// (`/gas` vs. `/v1/gas`, `coins_sent` vs. `transferredGasObjects`) and
    /// ensures a second request has indexed its own object rather than merely
    /// observing the first request's already-visible balance.
    public func faucet(_ address: SuiAddress) async throws {
        let previousCoins = try await suiCoins(of: address)
        let previousCoinCount = previousCoins.count
        var lastStatus = -1

        for path in ["/gas", "/v1/gas"] {
            let url = URL(string: "http://127.0.0.1:\(faucetPort)\(path)")!
            var request = URLRequest(url: url)
            request.httpMethod = "POST"
            request.timeoutInterval = 10
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONEncoder().encode(FaucetRequest(recipient: address.string))

            guard let (_, response) = try? await URLSession.shared.data(for: request),
                  let httpResponse = response as? HTTPURLResponse else {
                continue
            }

            lastStatus = httpResponse.statusCode

            if (200..<300).contains(httpResponse.statusCode) {
                try await waitForSuiCoinCount(of: address, atLeast: previousCoinCount + 1)
                return
            }
        }

        throw SuiLaunchError(description: "faucet request for \(address.string) failed (tried /gas, /v1/gas; last HTTP status \(lastStatus))")
    }

    private struct FaucetRequest: Encodable {
        struct Recipient: Encodable {
            let recipient: String
        }

        let fixedAmountRequest: Recipient

        enum CodingKeys: String, CodingKey {
            case fixedAmountRequest = "FixedAmountRequest"
        }

        init(recipient: String) {
            fixedAmountRequest = Recipient(recipient: recipient)
        }
    }

    /// The current epoch's reference gas price, for building a transaction.
    public func referenceGasPrice() async throws -> UInt64 {
        try await withLedgerServiceClient { ledger in
            var request = Sui_Rpc_V2_GetEpochRequest()
            request.readMask.paths = ["reference_gas_price"]

            let response = try await ledger.getEpoch(
                request: ClientRequest(message: request),
                options: Self.callOptions
            )

            return response.epoch.referenceGasPrice
        }
    }

    /// `address`'s owned native-SUI coin objects, largest balance first.
    /// Delegates to ``SuiGRPCClient/ownedCoins(of:coinType:)`` on the local
    /// node client rather than duplicating the gRPC + Base58 logic here.
    public func suiCoins(of address: SuiAddress) async throws -> [SuiCoinObject] {
        try await client().ownedCoins(of: address, coinType: "0x2::sui::SUI")
    }

    /// The largest native-SUI coin `address` owns — used as the sole gas
    /// payment object for the split-and-transfer PTBs this suite builds.
    ///
    /// - Throws: ``SuiLaunchError`` if `address` owns no SUI coins.
    public func largestSuiCoin(of address: SuiAddress) async throws -> SuiObjectReference {
        guard let largest = try await suiCoins(of: address).first else {
            throw SuiLaunchError(description: "\(address.string) owns no SUI coins")
        }

        return largest.reference
    }

    /// Polls until `address` owns at least `minimum` SUI coin objects, up to
    /// a 10-second timeout.
    ///
    /// - Throws: ``SuiLaunchError`` if the coin count doesn't reach
    ///   `minimum` within the timeout.
    public func waitForSuiCoinCount(of address: SuiAddress, atLeast minimum: Int) async throws {
        let deadline = ContinuousClock.now.advanced(by: Self.localnetTimeout)

        while ContinuousClock.now < deadline {
            if let coins = try? await suiCoins(of: address), coins.count >= minimum {
                return
            }

            try? await Task.sleep(for: .milliseconds(200))
        }

        throw SuiLaunchError(description: "\(address.string) didn't accumulate \(minimum) SUI coins within 10s")
    }

    /// Polls `LedgerService.GetTransaction` for `digest`'s effects, until
    /// it lands in a checkpoint. This is analogous to waiting for an EVM
    /// receipt, because a broadcast localnet transaction isn't
    /// necessarily final the instant `broadcast(transactionData:signature:)`
    /// returns.
    public func waitForEffects(_ digest: String) async throws -> Sui_Rpc_V2_TransactionEffects {
        let deadline = ContinuousClock.now.advanced(by: Self.localnetTimeout)

        while ContinuousClock.now < deadline {
            if let effects = try? await getEffects(digest) {
                return effects
            }

            try? await Task.sleep(for: .milliseconds(200))
        }

        throw SuiLaunchError(description: "no effects for \(digest) within 10s")
    }

    private func getEffects(_ digest: String) async throws -> Sui_Rpc_V2_TransactionEffects {
        try await withLedgerServiceClient { ledger in
            var request = Sui_Rpc_V2_GetTransactionRequest()
            request.digest = digest
            request.readMask.paths = ["effects"]

            let response = try await ledger.getTransaction(
                request: ClientRequest(message: request),
                options: Self.callOptions
            )

            return response.transaction.effects
        }
    }

    /// Polls ``SuiGRPCClient/nativeBalance(of:)`` for `address` until it
    /// differs from `previous` — the balance index updates on checkpoint
    /// commit, slightly after `waitForEffects(_:)` sees the transaction's
    /// own effects.
    public func waitForBalanceChange(of address: SuiAddress, from previous: UInt64) async throws -> UInt64 {
        let deadline = ContinuousClock.now.advanced(by: Self.localnetTimeout)

        while ContinuousClock.now < deadline {
            if let balance = try? await client().nativeBalance(of: address), balance != previous {
                return balance
            }

            try? await Task.sleep(for: .milliseconds(200))
        }

        throw SuiLaunchError(description: "\(address.string)'s balance didn't change from \(previous) within 10s")
    }

    private func transport() throws -> HTTP2ClientTransport.Posix {
        do {
            return try HTTP2ClientTransport.Posix(
                target: .dns(host: "127.0.0.1", port: Int(rpcPort)),
                transportSecurity: .plaintext
            )
        } catch {
            throw SuiLaunchError(description: "failed to build transport to 127.0.0.1:\(rpcPort): \(error.localizedDescription)")
        }
    }

    private func withLedgerServiceClient<Result: Sendable>(
        _ body: @escaping (Sui_Rpc_V2_LedgerService.Client<HTTP2ClientTransport.Posix>) async throws -> Result
    ) async throws -> Result {
        try await withGRPCClient(transport: try transport()) { grpcClient in
            try await body(Sui_Rpc_V2_LedgerService.Client(wrapping: grpcClient))
        }
    }
}
