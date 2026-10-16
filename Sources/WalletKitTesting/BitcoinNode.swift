#if os(macOS)

import Darwin
import Foundation
import WalletKit

/// An error raised when the local Bitcoin regtest node (`bitcoind` +
/// `electrs`) cannot be provisioned, started, or queried.
public struct BitcoinLaunchError: LocalizedError, CustomStringConvertible {
    /// A description of the failed local-node operation.
    public let description: String

    public var errorDescription: String? { description }

    /// Creates an error with a diagnostic description.
    public init(description: String) {
        self.description = description
    }
}

/// Binds five distinct ephemeral TCP ports via the kernel (port 0) and reads
/// back what it assigned, so concurrently-running tests each get their own
/// `bitcoind`/`electrs` pair instead of racing over hardcoded defaults — see
/// `EthereumNode`/`SuiNode`'s identical reasoning. All five sockets are kept
/// open until every port is chosen so the allocations can't collide with
/// each other.
private func freeTCPPorts(_ count: Int) throws -> [UInt16] {
    var fds: [Int32] = []
    defer { fds.forEach { close($0) } }

    var ports: [UInt16] = []

    for _ in 0..<count {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else {
            throw BitcoinLaunchError(description: "socket() failed while allocating a free port")
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
            throw BitcoinLaunchError(description: "bind() failed while allocating a free port")
        }

        var len = socklen_t(MemoryLayout<sockaddr_in>.size)
        let getResult = withUnsafeMutablePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                getsockname(fd, $0, &len)
            }
        }

        guard getResult == 0 else {
            throw BitcoinLaunchError(description: "getsockname() failed while allocating a free port")
        }

        ports.append(UInt16(bigEndian: addr.sin_port))
    }

    return ports
}

/// The five ports ``BitcoinNode/start()`` allocates for one `bitcoind`/`electrs` pair.
private struct AllocatedPorts {
    let p2p: UInt16
    let rpc: UInt16
    let electrum: UInt16
    let http: UInt16
    let monitoring: UInt16
}

/// `bitcoind` quietly binds an extra loopback listener at `p2pPort + 1`
/// (confirmed empirically with several distinct `-port` values — e.g.
/// `-port=42222` always also logs "Bound to 127.0.0.1:42223" — with no
/// `-bind` flag asking for it) — reroll the other four ports if the
/// kernel's ephemeral allocator (which hands out nearby ports for quick
/// successive binds far more often than true randomness would) happens
/// to pick that exact value for one of them.
private func allocatePorts() throws -> AllocatedPorts {
    let p2pPort = try freeTCPPorts(1)[0]
    let reservedPort = p2pPort + 1

    var otherPorts = try freeTCPPorts(4)
    var rerollAttempts = 0
    while otherPorts.contains(reservedPort), rerollAttempts < 5 {
        otherPorts = try freeTCPPorts(4)
        rerollAttempts += 1
    }

    guard !otherPorts.contains(reservedPort) else {
        throw BitcoinLaunchError(description: "could not allocate ports avoiding bitcoind's reserved port \(reservedPort)")
    }

    return AllocatedPorts(
        p2p: p2pPort,
        rpc: otherPorts[0],
        electrum: otherPorts[1],
        http: otherPorts[2],
        monitoring: otherPorts[3]
    )
}

/// Launches `bitcoind -regtest` against `ports`, already running by the time this returns.
private func launchBitcoind(
    dataDirectory: URL,
    path: String,
    ports: AllocatedPorts
) throws -> (process: Process, logHandle: FileHandle) {
    let logHandle = try makeLogHandle(at: dataDirectory.appendingPathComponent("bitcoind.log"))
    let process = Process()
    process.executableURL = URL(fileURLWithPath: path)
    process.arguments = [
        "-regtest",
        "-datadir=\(dataDirectory.path)",
        "-rpcport=\(ports.rpc)",
        "-port=\(ports.p2p)",
        "-fallbackfee=0.0001",
        "-printtoconsole"
    ]
    process.standardOutput = logHandle
    process.standardError = logHandle

    do {
        try process.run()
    } catch {
        throw BitcoinLaunchError(description: "failed to launch bitcoind at \(path): \(error.localizedDescription)")
    }

    return (process, logHandle)
}

/// Builds (but doesn't yet run) the `electrs` process against `ports` —
/// ``BitcoinNode/start()`` only starts it once `bitcoind`'s genesis
/// blocks are mined, so its initial sync has a non-empty chain to index.
private func makeElectrsProcess(
    dataDirectory: URL,
    dbDirectory: URL,
    path: String,
    ports: AllocatedPorts
) throws -> (process: Process, logHandle: FileHandle) {
    let logHandle = try makeLogHandle(at: dataDirectory.appendingPathComponent("electrs.log"))
    let process = Process()
    process.executableURL = URL(fileURLWithPath: path)
    process.arguments = [
        "--network", "regtest",
        "--daemon-dir", dataDirectory.path,
        "--daemon-rpc-addr", "127.0.0.1:\(ports.rpc)",
        "--db-dir", dbDirectory.path,
        "--electrum-rpc-addr", "127.0.0.1:\(ports.electrum)",
        "--http-addr", "127.0.0.1:\(ports.http)",
        "--monitoring-addr", "127.0.0.1:\(ports.monitoring)"
    ]
    process.standardOutput = logHandle
    process.standardError = logHandle
    return (process, logHandle)
}

/// A local `bitcoind -regtest` node fronted by `electrs` (Blockstream's
/// fork, which — unlike upstream `romanz/electrs` — indexes both the
/// Electrum wire protocol *and* an Esplora-compatible HTTP REST API from
/// the same process against the same chain state), for integration tests
/// that need a real Electrum or Esplora backend rather than a mock.
///
/// Unlike `EthereumNode`/`SuiNode`, neither tool has a `mise` registry entry
/// (checked: `mise registry` has no `bitcoind`/`electrs` backend), so
/// they aren't provisioned lazily here — `make bitcoin-testing` downloads
/// `bitcoind`/`bitcoin-cli` and builds `electrs` from source (a
/// multi-minute build the first time; no prebuilt binary exists for its
/// Esplora-enabled fork) into `WalletKit/.build/bitcoin-testing/bin/`
/// once, the same way `make walletkit-ffi` provisions the XCFramework
/// before the Swift side ever compiles. ``start()`` only resolves that
/// already-built path; run `make bitcoin-testing` from the `WalletKit`
/// directory before running this suite for the first time.
public final class BitcoinNode {
    /// `ElectrumBackend`'s connection target — plaintext (no TLS) for a
    /// local regtest node.
    public let electrumHost = "127.0.0.1"
    /// The local Electrum TCP port.
    public let electrumPort: UInt16

    /// `EsploraBackend`'s connection target.
    public let esploraEndpoint: URL

    private let bitcoinCLIPath: String
    private let rpcPort: UInt16
    private let dataDirectory: URL
    private let bitcoindProcess: Process
    private let electrsProcess: Process
    private let bitcoindLogHandle: FileHandle
    private let electrsLogHandle: FileHandle
    private let walletName = "test"

    private var esploraPort: UInt16 { UInt16(esploraEndpoint.port ?? 0) }

    private init(
        bitcoinCLIPath: String,
        rpcPort: UInt16,
        electrumPort: UInt16,
        esploraEndpoint: URL,
        dataDirectory: URL,
        bitcoindProcess: Process,
        electrsProcess: Process,
        bitcoindLogHandle: FileHandle,
        electrsLogHandle: FileHandle
    ) {
        self.bitcoinCLIPath = bitcoinCLIPath
        self.rpcPort = rpcPort
        self.electrumPort = electrumPort
        self.esploraEndpoint = esploraEndpoint
        self.dataDirectory = dataDirectory
        self.bitcoindProcess = bitcoindProcess
        self.electrsProcess = electrsProcess
        self.bitcoindLogHandle = bitcoindLogHandle
        self.electrsLogHandle = electrsLogHandle
    }

    /// Launches a fresh `bitcoind -regtest` plus `electrs` pair from the
    /// binaries `make bitcoin-testing` already provisioned, waiting until
    /// both are synced and ready.
    ///
    /// - Throws: ``BitcoinLaunchError`` if `make bitcoin-testing` hasn't
    ///   been run yet, either process fails to launch, or `electrs` never
    ///   finishes its initial sync within 15 seconds.
    public static func start() async throws -> BitcoinNode {
        let ports = try allocatePorts()
        let (bitcoindPath, bitcoinCLIPath, electrsPath) = try resolveProvisionedBinaries()

        let dataDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("bitcoin-regtest-\(UUID().uuidString)")
        let dbDirectory = dataDirectory.appendingPathComponent("electrs-db")
        try FileManager.default.createDirectory(at: dataDirectory, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: dbDirectory, withIntermediateDirectories: true)

        let (bitcoindProcess, bitcoindLogHandle) = try launchBitcoind(
            dataDirectory: dataDirectory,
            path: bitcoindPath,
            ports: ports
        )

        try await waitForCookie(dataDirectory: dataDirectory, process: bitcoindProcess)

        let (electrsProcess, electrsLogHandle) = try makeElectrsProcess(
            dataDirectory: dataDirectory,
            dbDirectory: dbDirectory,
            path: electrsPath,
            ports: ports
        )

        let esploraEndpoint = URL(string: "http://127.0.0.1:\(ports.http)")!
        let node = BitcoinNode(
            bitcoinCLIPath: bitcoinCLIPath,
            rpcPort: ports.rpc,
            electrumPort: ports.electrum,
            esploraEndpoint: esploraEndpoint,
            dataDirectory: dataDirectory,
            bitcoindProcess: bitcoindProcess,
            electrsProcess: electrsProcess,
            bitcoindLogHandle: bitcoindLogHandle,
            electrsLogHandle: electrsLogHandle
        )

        try await node.waitUntilRPCReady()
        try node.bitcoinCLI(["createwallet", node.walletName])

        // A freshly created regtest chain (zero blocks, no peers) stays
        // stuck reporting `initialblockdownload: true` forever — Bitcoin
        // Core only clears it once the chain tip is recent — and electrs
        // blocks its own startup sync waiting for that flag to clear.
        // Mining flips it immediately (the new tip's timestamp is
        // "now"), so this has to happen before electrs launches, not
        // after. 101 blocks rather than 1: a coinbase reward needs 100
        // confirmations before it's spendable (a consensus rule that
        // applies on regtest too), and ``fund(address:amountSats:)``
        // needs the wallet to actually have a spendable balance.
        let genesisAddress = try node.newWalletAddress()
        try node.bitcoinCLI(["-rpcwallet=\(node.walletName)", "generatetoaddress", "101", genesisAddress])

        do {
            try electrsProcess.run()
        } catch {
            bitcoindProcess.terminate()
            throw BitcoinLaunchError(description: "failed to launch electrs at \(electrsPath): \(error.localizedDescription)")
        }

        try await node.waitUntilElectrsReady()
        return node
    }

    /// Stops the Bitcoin and indexer processes.
    public func stop() {
        electrsProcess.terminateAndWait()
        bitcoindProcess.terminateAndWait()
        try? bitcoindLogHandle.close()
        try? electrsLogHandle.close()
        try? FileManager.default.removeItem(at: dataDirectory)
    }

    deinit {
        if electrsProcess.isRunning {
            electrsProcess.terminate()
        }

        if bitcoindProcess.isRunning {
            bitcoindProcess.terminate()
        }

        try? FileManager.default.removeItem(at: dataDirectory)
    }

    /// Mines `count` blocks, crediting the coinbase reward to `address`,
    /// and waits until `electrs` has indexed the new tip.
    public func mine(_ count: Int, to address: String) async throws {
        try bitcoinCLI(["-rpcwallet=\(walletName)", "generatetoaddress", String(count), address])
        try await waitForElectrsSync()
    }

    /// A fresh address owned by the node's own wallet — used as the
    /// mining reward destination when the caller doesn't need a specific
    /// address (e.g. to mature coins before funding a test account).
    public func newWalletAddress() throws -> String {
        try bitcoinCLI(["-rpcwallet=\(walletName)", "getnewaddress"])
    }

    /// Sends `amountSats` from the node's own wallet to `address`, mines
    /// one confirming block, and waits until `electrs` has indexed it —
    /// the fixture's `EthereumNode.faucetERC20`/`SuiNode.faucet` equivalent
    /// for funding a freshly derived Bitcoin account's receive address.
    ///
    /// - Returns: The funding transaction's txid.
    public func fund(address: String, amountSats: UInt64) async throws -> String {
        let amountBTC = Double(amountSats) / 100_000_000
        let txid = try bitcoinCLI([
            "-rpcwallet=\(walletName)", "sendtoaddress", address, String(format: "%.8f", amountBTC)
        ])
        try await mine(1, to: try newWalletAddress())
        return txid
    }

    /// Polls until `electrs`'s indexed tip height matches `bitcoind`'s own
    /// height, up to a 10-second timeout. Both the Electrum and HTTP APIs
    /// share one in-process index, so catching up on either observes the
    /// other's readiness too.
    public func waitForElectrsSync() async throws {
        let targetHeight = try Int(bitcoinCLI(["getblockcount"])) ?? 0
        let deadline = ContinuousClock.now.advanced(by: .seconds(10))

        while ContinuousClock.now < deadline {
            if let height = try? await esploraTipHeight(), height >= targetHeight {
                return
            }

            try? await Task.sleep(for: .milliseconds(100))
        }

        throw BitcoinLaunchError(description: "electrs never caught up to height \(targetHeight) within 10s")
    }

    private func esploraTipHeight() async throws -> Int {
        let (data, response) = try await URLSession.shared.data(
            for: URLRequest(url: esploraEndpoint.appendingPathComponent("blocks/tip/height"))
        )

        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode),
              let text = String(data: data, encoding: .utf8), let height = Int(text) else {
            throw BitcoinLaunchError(description: "malformed /blocks/tip/height response")
        }

        return height
    }

    private func waitUntilElectrsReady() async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(15))

        while ContinuousClock.now < deadline {
            // A plain TCP connect first: probing the HTTP endpoint while
            // electrs is still binding makes CFNetwork log a "Could not
            // connect to the server" error for every attempt.
            if isListening(port: esploraPort), (try? await esploraTipHeight()) != nil {
                return
            }

            try? await Task.sleep(for: .milliseconds(200))
        }

        let logURL = dataDirectory.appendingPathComponent("electrs.log")
        let log = (try? String(contentsOf: logURL, encoding: .utf8)) ?? "(no log)"
        throw BitcoinLaunchError(description: "electrs never became ready within 15s. Log tail:\n\(log.suffix(2000))")
    }

    /// Polls until `bitcoind` answers an RPC call. The cookie file appears
    /// before the daemon finishes warming up, and during warm-up every RPC
    /// fails with error -28 ("Loading block index…") — so the cookie alone
    /// doesn't mean `createwallet` will succeed.
    private func waitUntilRPCReady() async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(15))
        var lastError = "no attempt made"

        while ContinuousClock.now < deadline {
            do {
                try bitcoinCLI(["getblockcount"])
                return
            } catch {
                lastError = "\(error)"
            }

            try? await Task.sleep(for: .milliseconds(100))
        }

        throw BitcoinLaunchError(description: "bitcoind RPC never became ready within 15s: \(lastError)")
    }

    /// Whether something accepts TCP connections on `127.0.0.1:port`.
    private func isListening(port: UInt16) -> Bool {
        let fd = socket(AF_INET, SOCK_STREAM, 0)

        guard fd >= 0 else {
            return false
        }

        defer { close(fd) }

        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = port.bigEndian
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")

        let result = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }

        return result == 0
    }

    /// Polls until `bitcoind`'s cookie auth file exists, confirming the
    /// daemon has finished its own startup and is ready for RPC calls.
    private static func waitForCookie(dataDirectory: URL, process: Process) async throws {
        let cookiePath = dataDirectory.appendingPathComponent("regtest/.cookie").path
        let deadline = ContinuousClock.now.advanced(by: .seconds(15))

        while ContinuousClock.now < deadline {
            if FileManager.default.fileExists(atPath: cookiePath) {
                return
            }

            try? await Task.sleep(for: .milliseconds(100))
        }

        let logURL = dataDirectory.appendingPathComponent("bitcoind.log")
        let log = (try? String(contentsOf: logURL, encoding: .utf8)) ?? "(no log)"
        let status = process.isRunning ? "still running" : "exited with status \(process.terminationStatus)"
        throw BitcoinLaunchError(description: "bitcoind never wrote its cookie file within 15s (\(status)). Log tail:\n\(log.suffix(2000))")
    }

    @discardableResult
    private func bitcoinCLI(_ arguments: [String]) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: bitcoinCLIPath)
        process.arguments = ["-regtest", "-datadir=\(dataDirectory.path)", "-rpcport=\(rpcPort)"] + arguments

        let outputPipe = Pipe()
        let errorPipe = Pipe()
        process.standardOutput = outputPipe
        process.standardError = errorPipe

        do {
            try process.run()
        } catch {
            throw BitcoinLaunchError(description: "failed to run bitcoin-cli \(arguments.joined(separator: " ")): \(error.localizedDescription)")
        }

        process.waitUntilExit()

        let output = String(data: outputPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let errorOutput = String(data: errorPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

        guard process.terminationStatus == 0 else {
            throw BitcoinLaunchError(
                description: "bitcoin-cli \(arguments.joined(separator: " ")) failed: \(errorOutput.isEmpty ? output : errorOutput)"
            )
        }

        return output
    }
}

/// Resolves `make bitcoin-testing`'s already-provisioned binaries under
/// `WalletKit/.build/bitcoin-testing/bin/` — the same `SRCROOT`-or-
/// walk-up-from-`#filePath` trick `EthereumNode.resolveAnvilBinaryPath` uses
/// to find the `WalletKit` directory regardless of where the test host
/// (Xcode, `swift test`, CI) sets the working directory.
///
/// - Throws: ``BitcoinLaunchError`` naming the missing binary and
///   pointing at `make bitcoin-testing`, if it hasn't been run yet.
private func resolveProvisionedBinaries() throws -> ( // swiftlint:disable:this large_tuple
    bitcoind: String,
    bitcoinCLI: String,
    electrs: String
) {
    let sourceRoot = ProcessInfo.processInfo.environment["SRCROOT"]
        ?? URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent() // WalletKitTesting/
            .deletingLastPathComponent() // Sources/
            .deletingLastPathComponent() // WalletKit/
            .path

    let binDirectory = URL(fileURLWithPath: sourceRoot).appendingPathComponent(".build/bitcoin-testing/bin")
    let bitcoindPath = binDirectory.appendingPathComponent("bitcoind").path
    let bitcoinCLIPath = binDirectory.appendingPathComponent("bitcoin-cli").path
    let electrsPath = binDirectory.appendingPathComponent("electrs").path

    for (name, path) in [("bitcoind", bitcoindPath), ("bitcoin-cli", bitcoinCLIPath), ("electrs", electrsPath)] {
        guard FileManager.default.isExecutableFile(atPath: path) else {
            throw BitcoinLaunchError(
                description: "\(name) not found at \(path) — run `make bitcoin-testing` from the WalletKit directory first"
            )
        }
    }

    return (bitcoindPath, bitcoinCLIPath, electrsPath)
}

private func makeLogHandle(at url: URL) throws -> FileHandle {
    FileManager.default.createFile(atPath: url.path, contents: nil)
    return try FileHandle(forWritingTo: url)
}

#endif // swiftlint:disable:this file_length
