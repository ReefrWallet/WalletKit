#if os(macOS)

import Darwin
import Foundation
import WalletKit

/// An error raised when the local Bitcoin regtest node (`bitcoind` +
/// `electrs`) cannot be provisioned, started, or queried.
public struct BitcoinLaunchError: Error, CustomStringConvertible {
    public let description: String

    public init(description: String) {
        self.description = description
    }
}

/// Binds five distinct ephemeral TCP ports via the kernel (port 0) and reads
/// back what it assigned, so concurrently-running tests each get their own
/// `bitcoind`/`electrs` pair instead of racing over hardcoded defaults — see
/// `AnvilNode`/`SuiNode`'s identical reasoning. All five sockets are kept
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

/// A local `bitcoind -regtest` node fronted by `electrs` (Blockstream's
/// fork, which — unlike upstream `romanz/electrs` — indexes both the
/// Electrum wire protocol *and* an Esplora-compatible HTTP REST API from
/// the same process against the same chain state), for integration tests
/// that need a real backend behind ``ElectrumBackend``/``EsploraBackend``
/// rather than ``BitcoinTransactionBuilderTests``'s mock.
///
/// Unlike `AnvilNode`/`SuiNode`, neither tool has a `mise` registry entry
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
        // `bitcoind` quietly binds an extra loopback listener at
        // `p2pPort + 1` (confirmed empirically with several distinct
        // `-port` values — e.g. `-port=42222` always also logs "Bound to
        // 127.0.0.1:42223" — with no `-bind` flag asking for it) —
        // reroll the other four ports if the kernel's ephemeral allocator
        // (which hands out nearby ports for quick successive binds far
        // more often than true randomness would) happens to pick that
        // exact value for one of them.
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
        let (rpcPort, electrumPort, httpPort, monitoringPort) = (otherPorts[0], otherPorts[1], otherPorts[2], otherPorts[3])

        let (bitcoindPath, bitcoinCLIPath, electrsPath) = try resolveProvisionedBinaries()

        let dataDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("bitcoin-regtest-\(UUID().uuidString)")
        let dbDirectory = dataDirectory.appendingPathComponent("electrs-db")
        try FileManager.default.createDirectory(at: dataDirectory, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: dbDirectory, withIntermediateDirectories: true)

        let bitcoindLogHandle = try makeLogHandle(at: dataDirectory.appendingPathComponent("bitcoind.log"))
        let bitcoindProcess = Process()
        bitcoindProcess.executableURL = URL(fileURLWithPath: bitcoindPath)
        bitcoindProcess.arguments = [
            "-regtest",
            "-datadir=\(dataDirectory.path)",
            "-rpcport=\(rpcPort)",
            "-port=\(p2pPort)",
            "-fallbackfee=0.0001",
            "-printtoconsole"
        ]
        bitcoindProcess.standardOutput = bitcoindLogHandle
        bitcoindProcess.standardError = bitcoindLogHandle

        do {
            try bitcoindProcess.run()
        } catch {
            throw BitcoinLaunchError(description: "failed to launch bitcoind at \(bitcoindPath): \(error.localizedDescription)")
        }

        try await waitForCookie(dataDirectory: dataDirectory, process: bitcoindProcess)

        let electrsLogHandle = try makeLogHandle(at: dataDirectory.appendingPathComponent("electrs.log"))
        let electrsProcess = Process()
        electrsProcess.executableURL = URL(fileURLWithPath: electrsPath)
        electrsProcess.arguments = [
            "--network", "regtest",
            "--daemon-dir", dataDirectory.path,
            "--daemon-rpc-addr", "127.0.0.1:\(rpcPort)",
            "--db-dir", dbDirectory.path,
            "--electrum-rpc-addr", "127.0.0.1:\(electrumPort)",
            "--http-addr", "127.0.0.1:\(httpPort)",
            "--monitoring-addr", "127.0.0.1:\(monitoringPort)"
        ]
        electrsProcess.standardOutput = electrsLogHandle
        electrsProcess.standardError = electrsLogHandle

        let esploraEndpoint = URL(string: "http://127.0.0.1:\(httpPort)")!
        let node = BitcoinNode(
            bitcoinCLIPath: bitcoinCLIPath,
            rpcPort: rpcPort,
            electrumPort: electrumPort,
            esploraEndpoint: esploraEndpoint,
            dataDirectory: dataDirectory,
            bitcoindProcess: bitcoindProcess,
            electrsProcess: electrsProcess,
            bitcoindLogHandle: bitcoindLogHandle,
            electrsLogHandle: electrsLogHandle
        )

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

    public func stop() {
        electrsProcess.terminate()
        electrsProcess.waitUntilExit()
        bitcoindProcess.terminate()
        bitcoindProcess.waitUntilExit()
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
    /// the fixture's `AnvilNode.faucetERC20`/`SuiNode.faucet` equivalent
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
            if (try? await esploraTipHeight()) != nil {
                return
            }
            try? await Task.sleep(for: .milliseconds(200))
        }

        let log = (try? String(contentsOf: dataDirectory.appendingPathComponent("electrs.log"), encoding: .utf8)) ?? "(no log)"
        throw BitcoinLaunchError(description: "electrs never became ready within 15s. Log tail:\n\(log.suffix(2000))")
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

        let log = (try? String(contentsOf: dataDirectory.appendingPathComponent("bitcoind.log"), encoding: .utf8)) ?? "(no log)"
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
/// walk-up-from-`#filePath` trick `AnvilNode.resolveAnvilBinaryPath` uses
/// to find the `WalletKit` directory regardless of where the test host
/// (Xcode, `swift test`, CI) sets the working directory.
///
/// - Throws: ``BitcoinLaunchError`` naming the missing binary and
///   pointing at `make bitcoin-testing`, if it hasn't been run yet.
private func resolveProvisionedBinaries() throws -> (bitcoind: String, bitcoinCLI: String, electrs: String) {
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

#endif
