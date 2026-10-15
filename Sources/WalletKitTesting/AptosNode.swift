#if os(macOS)

import Darwin
import Foundation
import WalletKit

/// An error raised when the local Aptos network cannot be provisioned,
/// started, or queried.
public struct AptosLaunchError: Error, CustomStringConvertible {
    public let description: String

    public init(description: String) {
        self.description = description
    }
}

/// Admits one localnet per test process for its whole lifetime: the node
/// binds fixed network ports, so a second concurrent one fails to start.
private actor AptosNodeGate {
    static let shared = AptosNodeGate()

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

/// A local `aptos node run-localnet` (validator, REST API, and faucet; no
/// indexer, which needs Docker).
///
/// mise has no `aptos` entry, so `make aptos-testing` downloads the pinned
/// release into `WalletKit/.build/aptos-testing/bin/` once; ``start()`` only
/// resolves it.
public final class AptosNode {
    /// Per-operation bound (REST call, faucet, commit polling).
    private static let operationTimeout: Duration = .seconds(10)

    /// Genesis until the ready server answers. Measured 15–18s on an Apple
    /// Silicon Mac (~19s on x86 Linux); 90s is ≥ 5×.
    private static let startupTimeout: Duration = .seconds(90)

    /// The node's REST endpoint, e.g. `http://127.0.0.1:PORT/v1`.
    public let rpcURL: URL
    private let faucetURL: URL
    private let readyURL: URL
    private let process: Process
    private let workingDirectory: URL
    private let logHandle: FileHandle
    private var isStopped = false

    private init(
        rpcURL: URL,
        faucetURL: URL,
        readyURL: URL,
        process: Process,
        workingDirectory: URL,
        logHandle: FileHandle
    ) {
        self.rpcURL = rpcURL
        self.faucetURL = faucetURL
        self.readyURL = readyURL
        self.process = process
        self.workingDirectory = workingDirectory
        self.logHandle = logHandle
    }

    /// Starts a fresh localnet on free ports and waits until it's ready.
    ///
    /// - Throws: ``AptosLaunchError`` if `make aptos-testing` hasn't run, the
    ///   process fails to launch, or the node isn't ready within 90 seconds.
    public static func start() async throws -> AptosNode {
        let binary = try resolveProvisionedBinary()

        await AptosNodeGate.shared.acquire()

        let node: AptosNode
        do {
            node = try launch(binary: binary)
        } catch {
            await AptosNodeGate.shared.release()
            throw error
        }

        do {
            try await node.waitUntilReady()
        } catch {
            node.stop()
            throw error
        }

        return node
    }

    private static func launch(binary: URL) throws -> AptosNode {
        // The localnet binds fixed ports (network, backup, admin), so a node
        // orphaned by a killed test run blocks every later start.
        terminateOrphanedNodes()

        let ports = try freeTCPPorts(3)
        let (apiPort, faucetPort, readyPort) = (ports[0], ports[1], ports[2])

        let workingDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("aptos-localnet-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: workingDirectory, withIntermediateDirectories: true)

        // The REST port has no CLI flag; the admin service's fixed port would
        // collide between concurrent nodes.
        let override = workingDirectory.appendingPathComponent("override.yaml")
        try """
        api:
          address: "127.0.0.1:\(apiPort)"
        admin_service:
          enabled: false
        inspection_service:
          port: 0
        storage:
          backup_service_address: "127.0.0.1:0"
        """.write(to: override, atomically: true, encoding: .utf8)

        let logURL = workingDirectory.appendingPathComponent("aptos.log")
        FileManager.default.createFile(atPath: logURL.path, contents: nil)
        let logHandle = try FileHandle(forWritingTo: logURL)

        let process = Process()
        process.executableURL = binary
        process.arguments = [
            "node", "run-localnet",
            "--test-dir", workingDirectory.appendingPathComponent("node").path,
            "--force-restart", "--assume-yes", "--no-txn-stream",
            "--faucet-port", String(faucetPort),
            "--ready-server-listen-port", String(readyPort),
            "--test-config-override", override.path
        ]
        // Keep the CLI's global config out of the real `~/.aptos`.
        process.environment = ["HOME": workingDirectory.path, "PATH": "/usr/bin:/bin"]
        process.standardOutput = logHandle
        process.standardError = logHandle

        do {
            try process.run()
        } catch {
            throw AptosLaunchError(description: "failed to launch \(binary.path): \(error.localizedDescription)")
        }

        return AptosNode(
            rpcURL: URL(string: "http://127.0.0.1:\(apiPort)/v1")!,
            faucetURL: URL(string: "http://127.0.0.1:\(faucetPort)")!,
            readyURL: URL(string: "http://127.0.0.1:\(readyPort)/")!,
            process: process,
            workingDirectory: workingDirectory,
            logHandle: logHandle
        )
    }

    /// A client for this node (no indexer).
    public func client() -> AptosClient {
        AptosClient(endpoint: rpcURL, indexerURL: nil, apiKey: nil)
    }

    /// Stops the node, removes its temporary files, and admits the next node.
    public func stop() {
        guard !isStopped else {
            return
        }

        isStopped = true
        process.terminateAndWait()
        try? logHandle.close()
        try? FileManager.default.removeItem(at: workingDirectory)
        Task { await AptosNodeGate.shared.release() }
    }

    deinit {
        guard !isStopped else {
            return
        }

        if process.isRunning {
            process.terminateAndWait()
        }

        try? FileManager.default.removeItem(at: workingDirectory)
        Task { await AptosNodeGate.shared.release() }
    }

    /// Mints `octas` of APT to `address` and waits for the mint to commit.
    public func fund(_ address: AptosAddress, octas: UInt64) async throws {
        var components = URLComponents(url: faucetURL.appending(path: "mint"), resolvingAgainstBaseURL: false)!
        components.queryItems = [
            URLQueryItem(name: "amount", value: String(octas)),
            URLQueryItem(name: "address", value: address.longString)
        ]

        var request = URLRequest(url: components.url!)
        request.httpMethod = "POST"
        request.timeoutInterval = 10

        let (data, response) = try await URLSession.shared.data(for: request)

        guard (response as? HTTPURLResponse)?.statusCode == 200,
              let hashes = try? JSONDecoder().decode([String].self, from: data),
              let hash = hashes.first else {
            let responseBody = String(bytes: data, encoding: .utf8) ?? ""
            throw AptosLaunchError(description: "faucet mint for \(address.string) failed: \(responseBody)")
        }

        _ = try await waitForCommit("0x" + hash.replacingOccurrences(of: "0x", with: ""))
    }

    /// Polls until `hash` commits, up to 10 seconds.
    ///
    /// - Throws: ``AptosLaunchError`` on timeout or a failed transaction.
    @discardableResult
    public func waitForCommit(_ hash: String) async throws -> AptosTransactionStatus {
        guard let status = try await client().waitForTransaction(hash, timeout: Self.operationTimeout) else {
            throw AptosLaunchError(description: "\(hash) didn't commit within 10s")
        }

        guard status.success == true else {
            throw AptosLaunchError(description: "\(hash) failed: \(status.vmStatus ?? "unknown")")
        }

        return status
    }

    private func waitUntilReady() async throws {
        let deadline = ContinuousClock.now.advanced(by: Self.startupTimeout)

        while ContinuousClock.now < deadline {
            var request = URLRequest(url: readyURL)
            request.timeoutInterval = 2

            if let (_, response) = try? await URLSession.shared.data(for: request),
               (response as? HTTPURLResponse)?.statusCode == 200 {
                return
            }

            guard process.isRunning else {
                break
            }

            try? await Task.sleep(for: .milliseconds(250))
        }

        let log = (try? String(contentsOf: workingDirectory.appendingPathComponent("aptos.log"), encoding: .utf8))
            ?? "(no log)"
        throw AptosLaunchError(description: "aptos localnet never became ready. Log tail:\n\(log.suffix(2000))")
    }
}

/// Distinct ephemeral ports, held open together so they can't collide.
private func freeTCPPorts(_ count: Int) throws -> [UInt16] {
    var fds: [Int32] = []
    defer { fds.forEach { close($0) } }

    return try (0..<count).map { _ in
        let fd = socket(AF_INET, SOCK_STREAM, 0)

        guard fd >= 0 else {
            throw AptosLaunchError(description: "socket() failed while allocating a free port")
        }

        fds.append(fd)

        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_addr.s_addr = INADDR_ANY
        addr.sin_port = 0

        let bound = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }

        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let named = withUnsafeMutablePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                getsockname(fd, $0, &length)
            }
        }

        guard bound == 0, named == 0 else {
            throw AptosLaunchError(description: "bind()/getsockname() failed while allocating a free port")
        }

        return UInt16(bigEndian: addr.sin_port)
    }
}

/// Kills localnets this helper started whose test process has since died
/// (re-parented to launchd). Live nodes and unrelated processes are left alone.
private func terminateOrphanedNodes() {
    let ps = Process()
    ps.executableURL = URL(fileURLWithPath: "/bin/ps")
    ps.arguments = ["-axo", "pid=,ppid=,args="]
    let pipe = Pipe()
    ps.standardOutput = pipe

    guard (try? ps.run()) != nil else {
        return
    }

    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    let output = String(bytes: data, encoding: .utf8) ?? ""
    ps.waitUntilExit()

    for line in output.split(separator: "\n") {
        let fields = line.split(separator: " ", maxSplits: 2, omittingEmptySubsequences: true)

        guard fields.count == 3, fields[1] == "1", fields[2].contains("run-localnet"),
              fields[2].contains("/aptos-localnet-"), let pid = Int32(fields[0]) else {
            continue
        }

        kill(pid, SIGKILL)
    }
}

private func resolveProvisionedBinary() throws -> URL {
    let sourceRoot = ProcessInfo.processInfo.environment["SRCROOT"]
        ?? URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent() // WalletKitTesting/
        .deletingLastPathComponent() // Sources/
        .deletingLastPathComponent() // WalletKit/
        .path

    let binary = URL(fileURLWithPath: sourceRoot).appendingPathComponent(".build/aptos-testing/bin/aptos")

    guard FileManager.default.isExecutableFile(atPath: binary.path) else {
        throw AptosLaunchError(description: "aptos not found at \(binary.path) — run `make aptos-testing` in WalletKit first")
    }

    return binary
}

#endif
