#if os(macOS)

import Darwin
import Foundation
import WalletKit

/// An error raised when the local `solana-test-validator` node cannot be
/// provisioned, started, or queried.
public struct SolanaLaunchError: Error, CustomStringConvertible {
    /// A description of the failed local-node operation.
    public let description: String

    /// Creates an error with a diagnostic description.
    public init(description: String) {
        self.description = description
    }
}

/// Binds two distinct ephemeral TCP ports via the kernel (port 0) and reads
/// back what it assigned, so concurrently-running tests each get their own
/// `solana-test-validator` instance instead of racing over hardcoded
/// defaults — see `BitcoinNode`/`SuiNode`'s identical reasoning.
private func freeTCPPorts(_ count: Int) throws -> [UInt16] {
    var fds: [Int32] = []
    defer { fds.forEach { close($0) } }

    var ports: [UInt16] = []

    for _ in 0..<count {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else {
            throw SolanaLaunchError(description: "socket() failed while allocating a free port")
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
            throw SolanaLaunchError(description: "bind() failed while allocating a free port")
        }

        var len = socklen_t(MemoryLayout<sockaddr_in>.size)
        let getResult = withUnsafeMutablePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                getsockname(fd, $0, &len)
            }
        }

        guard getResult == 0 else {
            throw SolanaLaunchError(description: "getsockname() failed while allocating a free port")
        }

        ports.append(UInt16(bigEndian: addr.sin_port))
    }

    return ports
}

/// A local `solana-test-validator` node for integration tests that need a real backend behind
/// ``SolanaRPCClient`` rather than a mock. Unlike `bitcoind`/`electrs` (two processes) or Sui's
/// `sui start`, one binary serves both RPC and the airdrop faucet, and the SPL Token/Token-2022/
/// Associated-Token-Account programs are already present in its default genesis — no
/// `--bpf-program`/`--clone` setup needed.
///
/// No `mise` registry entry exists for any of the Agave binaries this wraps (checked: `mise
/// registry` has no `solana` backend), so — like `BitcoinNode` — this isn't provisioned lazily:
/// `make solana-testing` downloads the official release tarball into
/// `WalletKit/.build/solana-testing/bin/` once; ``start()`` only resolves that already-provisioned
/// path.
public final class SolanaNode {
    /// The local validator's JSON-RPC endpoint.
    public let rpcURL: URL
    let binDirectory: URL

    private let process: Process
    private let logHandle: FileHandle
    private let ledgerDirectory: URL

    private init(rpcURL: URL, binDirectory: URL, process: Process, logHandle: FileHandle, ledgerDirectory: URL) {
        self.rpcURL = rpcURL
        self.binDirectory = binDirectory
        self.process = process
        self.logHandle = logHandle
        self.ledgerDirectory = ledgerDirectory
    }

    /// Launches a fresh `solana-test-validator` from the binaries `make
    /// solana-testing` already provisioned, waiting until its RPC port
    /// reports healthy.
    ///
    /// - Throws: ``SolanaLaunchError`` if `make solana-testing` hasn't
    ///   been run yet, the process fails to launch, or it never reports
    ///   healthy within 30 seconds (a fresh validator's first slot can
    ///   take a few seconds longer to produce than an already-warm one).
    public static func start() async throws -> SolanaNode {
        let ports = try freeTCPPorts(2)
        let (rpcPort, faucetPort) = (ports[0], ports[1])

        let binDirectory = try resolveProvisionedBinaries()
        let ledgerDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("solana-test-ledger-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: ledgerDirectory, withIntermediateDirectories: true)

        let logHandle = try makeLogHandle(at: ledgerDirectory.appendingPathComponent("solana-test-validator.log"))
        let process = Process()
        process.executableURL = binDirectory.appendingPathComponent("solana-test-validator")
        process.arguments = [
            "--ledger", ledgerDirectory.path,
            "--rpc-port", "\(rpcPort)",
            "--faucet-port", "\(faucetPort)",
            "--quiet",
            "--reset"
        ]
        process.standardOutput = logHandle
        process.standardError = logHandle

        do {
            try process.run()
        } catch {
            throw SolanaLaunchError(
                description: "failed to launch solana-test-validator: \(error.localizedDescription)"
            )
        }

        let rpcURL = URL(string: "http://127.0.0.1:\(rpcPort)")!

        let node = SolanaNode(
            rpcURL: rpcURL,
            binDirectory: binDirectory,
            process: process,
            logHandle: logHandle,
            ledgerDirectory: ledgerDirectory
        )

        try await node.waitUntilReady()
        return node
    }

    /// Stops the validator and removes its temporary ledger.
    public func stop() {
        process.terminateAndWait()
        try? logHandle.close()
        try? FileManager.default.removeItem(at: ledgerDirectory)
    }

    deinit {
        if process.isRunning {
            process.terminate()
        }

        try? FileManager.default.removeItem(at: ledgerDirectory)
    }

    /// Requests `lamports` of native SOL for `address` from the
    /// validator's built-in faucet and waits for the airdrop transaction
    /// to confirm.
    ///
    /// - Returns: The airdrop transaction's signature.
    public func airdrop(to address: SolanaAddress, lamports: UInt64) async throws -> String {
        struct Envelope: Encodable {
            let jsonrpc = "2.0"
            let id = 1
            let method = "requestAirdrop"
            let params: [AnyEncodableParam]
        }

        struct AnyEncodableParam: Encodable {
            let string: String?
            let integer: UInt64?
            func encode(to encoder: Encoder) throws {
                var container = encoder.singleValueContainer()
                if let string { try container.encode(string) } else if let integer { try container.encode(integer) }
            }
        }

        struct Response: Decodable {
            let result: String?
            let error: RPCError?
        }

        struct RPCError: Decodable {
            let message: String
        }

        let envelope = Envelope(params: [
            AnyEncodableParam(string: address.string, integer: nil),
            AnyEncodableParam(string: nil, integer: lamports)
        ])
        let response: Response = try await call(envelope)
        guard let signature = response.result else {
            throw SolanaLaunchError(description: "requestAirdrop failed: \(response.error?.message ?? "unknown error")")
        }

        try await waitForConfirmation(signature: signature)
        return signature
    }

    /// Creates a new SPL mint with `decimals`, mints `amount` of it into `owner`'s associated
    /// token account (created if needed), using an ephemeral, freshly airdropped keypair as the
    /// `spl-token` CLI's own fee-payer/mint-authority (unrelated to any WalletKit-derived key).
    ///
    /// - Returns: The new mint's address.
    public func mintSPLToken(decimals: UInt8, to owner: SolanaAddress, amount: UInt64) async throws -> SolanaAddress {
        let keypairPath = ledgerDirectory.appendingPathComponent("spl-token-cli-\(UUID().uuidString).json").path
        try solanaKeygen(["new", "--no-bip39-passphrase", "--silent", "--outfile", keypairPath])
        let cliPubkey = try solanaKeygen(["pubkey", keypairPath])
        _ = try await airdrop(to: try SolanaAddress(string: cliPubkey), lamports: 10_000_000_000)

        let createTokenOutput = try splToken([
            "create-token", "--decimals", "\(decimals)",
            "--fee-payer", keypairPath, "--mint-authority", keypairPath
        ])
        guard let mintAddressLine = createTokenOutput.split(separator: "\n").first(where: { $0.contains("Address:") }),
              let mintAddress = mintAddressLine.split(separator: " ").last else {
            throw SolanaLaunchError(description: "could not parse mint address from spl-token output:\n\(createTokenOutput)")
        }

        let mint = try SolanaAddress(string: String(mintAddress))
        // `spl-token` reports success once its transaction is merely
        // "confirmed"; a subsequent `getAccountInfo` at the RPC's default
        // "finalized" commitment can still race ahead of that — wait for
        // finality explicitly rather than assuming CLI success implies it.
        try await waitForAccountToExist(mint)

        _ = try splToken([
            "create-account", mint.string, "--owner", owner.string, "--fee-payer", keypairPath
        ])
        // `mint`'s destination positional defaults to the ATA of
        // `--mint-authority` (the ephemeral CLI keypair), not `owner` —
        // it must be passed explicitly to land in the account
        // `create-account` above just created.
        let destinationATA = try SolanaProgram.associatedTokenAddress(owner: owner, mint: mint)
        _ = try splToken([
            "mint", mint.string, decimalAmount(amount, decimals: decimals), destinationATA.string,
            "--fee-payer", keypairPath, "--mint-authority", keypairPath
        ])
        try await waitForAccountToExist(destinationATA)

        return mint
    }

    /// Polls `getAccountInfo` at `confirmed` commitment until `address`
    /// exists, up to a 20-second timeout — see
    /// ``waitForConfirmation(signature:)``'s doc comment for why a CLI
    /// tool reporting success isn't itself sufficient (its own wait uses
    /// `confirmed` too, but that's still a separate poll against a
    /// different RPC method).
    private func waitForAccountToExist(_ address: SolanaAddress) async throws {
        struct Envelope: Encodable {
            let jsonrpc = "2.0"
            let id = 1
            let method = "getAccountInfo"
            let params: AccountInfoParams
        }

        struct AccountInfoParams: Encodable {
            let pubkey: String

            private struct Config: Encodable {
                // Plain `base58` (the RPC default with no `encoding`
                // param) fails outright — `-32600 Encoded binary (base
                // 58) data should be less than 128 bytes` — for any
                // account whose data exceeds that, which an SPL token
                // account's ~165-byte layout always does.
                let encoding = "base64"
                let commitment = "confirmed"
            }

            func encode(to encoder: Encoder) throws {
                var container = encoder.unkeyedContainer()
                try container.encode(pubkey)
                try container.encode(Config())
            }
        }

        struct Response: Decodable {
            let result: ResultValue?
        }

        struct ResultValue: Decodable {
            let value: AccountInfoValue?
        }

        struct AccountInfoValue: Decodable {
            let lamports: UInt64
        }

        let envelope = Envelope(params: AccountInfoParams(pubkey: address.string))
        let deadline = ContinuousClock.now.advanced(by: .seconds(20))
        while ContinuousClock.now < deadline {
            let response: Response = try await call(envelope)
            if response.result?.value != nil {
                return
            }

            try? await Task.sleep(for: .milliseconds(200))
        }

        throw SolanaLaunchError(description: "account \(address.string) never became visible within 20s")
    }

    /// Polls `getSignatureStatuses` until `signature` reaches at least
    /// `confirmed` status, up to a 20-second timeout.
    ///
    /// - Throws: ``SolanaLaunchError`` if the transaction fails on-chain
    ///   or never confirms within the timeout.
    public func waitForConfirmation(signature: String) async throws {
        struct Envelope: Encodable {
            let jsonrpc = "2.0"
            let id = 1
            let method = "getSignatureStatuses"
            let params: [[String]]
        }

        struct IgnoredValue: Decodable {
            init(from decoder: Decoder) throws {
                _ = try decoder.singleValueContainer()
            }
        }

        struct StatusValue: Decodable {
            let confirmationStatus: String?
            let err: IgnoredValue?
        }

        struct Response: Decodable {
            let result: ResultValue?
        }

        struct ResultValue: Decodable {
            let value: [StatusValue?]
        }

        let deadline = ContinuousClock.now.advanced(by: .seconds(20))
        while ContinuousClock.now < deadline {
            let response: Response = try await call(Envelope(params: [[signature]]))
            if let status = response.result?.value.first, let status {
                if status.err != nil {
                    throw SolanaLaunchError(description: "transaction \(signature) failed on-chain")
                }

                // Waits for "confirmed" (or better) specifically, not
                // just any non-nil status — "processed" alone doesn't
                // guarantee the cluster has converged on this block, and
                // ``SolanaRPCClient``'s own reads use `confirmed`
                // commitment (not the RPC default `finalized`, which
                // lags behind by the ~32-slot optimistic-confirmation
                // lockout window — tens of seconds even on an idle
                // single-node validator).
                if status.confirmationStatus == "confirmed" || status.confirmationStatus == "finalized" {
                    return
                }
            }

            try? await Task.sleep(for: .milliseconds(200))
        }

        throw SolanaLaunchError(description: "transaction \(signature) never confirmed within 20s")
    }
}

private extension SolanaNode {
    struct HealthResponse: Decodable {
        let result: String?
    }

    func waitUntilReady() async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(30))
        while ContinuousClock.now < deadline {
            struct Envelope: Encodable {
                let jsonrpc = "2.0"
                let id = 1
                let method = "getHealth"
            }

            if let response: HealthResponse = try? await call(Envelope()), response.result == "ok" {
                return
            }

            try? await Task.sleep(for: .milliseconds(200))
        }

        let logURL = ledgerDirectory.appendingPathComponent("solana-test-validator.log")
        let log = (try? String(contentsOf: logURL, encoding: .utf8)) ?? "(no log)"
        throw SolanaLaunchError(description: "solana-test-validator never became healthy within 30s. Log tail:\n\(log.suffix(2000))")
    }

    func call<Params: Encodable, Result: Decodable>(_ envelope: Params) async throws -> Result {
        var request = URLRequest(url: rpcURL)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(envelope)
        request.timeoutInterval = 10

        let (data, _) = try await URLSession.shared.data(for: request)
        return try JSONDecoder().decode(Result.self, from: data)
    }

    /// Formats `amount` (in the mint's smallest unit) as the decimal
    /// token-amount string `spl-token mint` expects on its command line.
    func decimalAmount(_ amount: UInt64, decimals: UInt8) -> String {
        guard decimals > 0 else {
            return "\(amount)"
        }

        var divisor: UInt64 = 1
        for _ in 0..<decimals { divisor *= 10 }

        let whole = amount / divisor
        let fraction = amount % divisor
        return "\(whole).\(String(format: "%0\(decimals)d", fraction))"
    }

    @discardableResult
    func solanaKeygen(_ arguments: [String]) throws -> String {
        try runProcess(binDirectory.appendingPathComponent("solana-keygen").path, arguments)
    }

    @discardableResult
    func splToken(_ arguments: [String]) throws -> String {
        let splTokenPath = binDirectory.appendingPathComponent("spl-token").path
        return try runProcess(splTokenPath, arguments + ["--url", rpcURL.absoluteString])
    }

    @discardableResult
    func runProcess(_ executablePath: String, _ arguments: [String]) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executablePath)
        process.arguments = arguments

        let outputPipe = Pipe()
        let errorPipe = Pipe()
        process.standardOutput = outputPipe
        process.standardError = errorPipe

        do {
            try process.run()
        } catch {
            throw SolanaLaunchError(
                description: "failed to run \(executablePath) \(arguments.joined(separator: " ")): \(error.localizedDescription)"
            )
        }

        process.waitUntilExit()

        let output = String(data: outputPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let errorOutput = String(data: errorPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

        guard process.terminationStatus == 0 else {
            throw SolanaLaunchError(
                description: "\(executablePath) \(arguments.joined(separator: " ")) failed: \(errorOutput.isEmpty ? output : errorOutput)"
            )
        }

        return output
    }
}

/// Resolves `make solana-testing`'s already-provisioned binaries under
/// `WalletKit/.build/solana-testing/bin/` — the same `SRCROOT`-or-
/// walk-up-from-`#filePath` trick `BitcoinNode`'s equivalent uses.
///
/// - Throws: ``SolanaLaunchError`` naming the missing binary and
///   pointing at `make solana-testing`, if it hasn't been run yet.
private func resolveProvisionedBinaries() throws -> URL {
    let sourceRoot = ProcessInfo.processInfo.environment["SRCROOT"]
        ?? URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent() // WalletKitTesting/
            .deletingLastPathComponent() // Sources/
            .deletingLastPathComponent() // WalletKit/
            .path

    let binDirectory = URL(fileURLWithPath: sourceRoot).appendingPathComponent(".build/solana-testing/bin")

    for name in ["solana-test-validator", "solana-keygen", "spl-token"] {
        guard FileManager.default.isExecutableFile(atPath: binDirectory.appendingPathComponent(name).path) else {
            throw SolanaLaunchError(
                description: "\(name) not found at \(binDirectory.path) — run `make solana-testing` from the WalletKit directory first"
            )
        }
    }

    return binDirectory
}

private func makeLogHandle(at url: URL) throws -> FileHandle {
    FileManager.default.createFile(atPath: url.path, contents: nil)
    return try FileHandle(forWritingTo: url)
}

#endif // swiftlint:disable:this file_length
