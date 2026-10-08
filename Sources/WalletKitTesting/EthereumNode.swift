#if os(macOS)

import BigInt
import Darwin
import Foundation
import WalletKit

/// An error raised when the local Anvil test node cannot be started or queried.
public struct EthereumLaunchError: Error, CustomStringConvertible {
    /// A description of the failed local-node operation.
    public let description: String

    /// Creates an error with a diagnostic description.
    public init(description: String) {
        self.description = description
    }
}

/// Binds an ephemeral TCP port via the kernel (port 0) and reads back what it
/// assigned, so concurrently-running tests each get Anvil listening on a
/// distinct port instead of racing over one hardcoded default — Swift Testing
/// parallelizes across suites by default, and two `anvil` processes fighting
/// over the same port silently attach to whichever one wins the bind, letting
/// unrelated tests corrupt each other's chain state.
private func freeTCPPort() throws -> UInt16 {
    let fd = socket(AF_INET, SOCK_STREAM, 0)

    guard fd >= 0 else {
        throw EthereumLaunchError(description: "socket() failed while allocating a free port")
    }

    defer { close(fd) }

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
        throw EthereumLaunchError(description: "bind() failed while allocating a free port")
    }

    var len = socklen_t(MemoryLayout<sockaddr_in>.size)

    let getResult = withUnsafeMutablePointer(to: &addr) {
        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
            getsockname(fd, $0, &len)
        }
    }

    guard getResult == 0 else {
        throw EthereumLaunchError(description: "getsockname() failed while allocating a free port")
    }

    return UInt16(bigEndian: addr.sin_port)
}

/// The subset of an Ethereum transaction receipt needed by local integration tests.
public struct TransactionReceipt: Decodable {
    /// The transaction execution status reported by Anvil.
    public let status: String
    /// The gas consumed by the transaction, encoded as an RPC quantity.
    public let gasUsed: String
    /// The gas price paid by the transaction, when available.
    public let effectiveGasPrice: String?
    /// The created contract address, for contract-creation transactions.
    public let contractAddress: String?
}

/// A local Foundry Anvil node used by integration tests.
public final class EthereumNode {
    /// The local JSON-RPC endpoint.
    public let endpoint: URL
    /// The Sepolia-compatible chain identifier used by the node.
    public let chainId: UInt64 = 0xaa36a7

    private let process: Process
    private let rpc: AnvilRPCClient
    private let workingDirectory: URL
    private let logHandle: FileHandle

    private init(process: Process, endpoint: URL, workingDirectory: URL, logHandle: FileHandle) {
        self.process = process
        self.endpoint = endpoint
        rpc = AnvilRPCClient(endpoint: endpoint)
        self.workingDirectory = workingDirectory
        self.logHandle = logHandle
    }

    /// Launches Anvil through the repository's mise-managed Foundry tool.
    ///
    /// - Parameter port: Pass an explicit port to pin it; otherwise a free
    ///   one is allocated per call so concurrently-running tests don't race
    ///   over the same Anvil instance.
    /// - Parameter workingDirectory: An optional directory for node logs and
    ///   state. A temporary directory is created when omitted.
    public static func start(
        port: UInt16? = nil,
        workingDirectory: URL? = nil
    ) async throws -> EthereumNode {
        let port = try port ?? freeTCPPort()
        guard let misePath = MiseTool.path else {
            throw EthereumLaunchError(
                description: "mise was not found in PATH or the host user's .local/bin directory"
            )
        }

        let sourceRoot = workingDirectory?.path
            ?? ProcessInfo.processInfo.environment["SRCROOT"]
            ?? URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .path

        let anvilPath = try resolveAnvilBinaryPath(misePath: misePath, sourceRoot: sourceRoot)
        let processWorkingDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("anvil-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: processWorkingDirectory, withIntermediateDirectories: true)
        let logURL = processWorkingDirectory.appendingPathComponent("anvil.log")
        FileManager.default.createFile(atPath: logURL.path, contents: nil)
        let logHandle = try FileHandle(forWritingTo: logURL)

        let process = Process()
        process.executableURL = URL(fileURLWithPath: anvilPath)
        process.currentDirectoryURL = URL(fileURLWithPath: sourceRoot)
        process.environment = MiseTool.processEnvironment
        process.arguments = [
            "--port", String(port), "--chain-id", String(0xaa36a7)
        ]
        process.standardOutput = logHandle
        process.standardError = logHandle

        do {
            try process.run()
        } catch {
            throw EthereumLaunchError(
                description: "failed to launch anvil at \(anvilPath): \(error.localizedDescription)"
            )
        }

        let endpoint = URL(string: "http://127.0.0.1:\(port)")!
        let node = EthereumNode(
            process: process,
            endpoint: endpoint,
            workingDirectory: processWorkingDirectory,
            logHandle: logHandle
        )

        try await node.waitUntilReady()
        return node
    }

    /// Stops the node and releases its resources.
    public func stop() {
        process.terminateAndWait()
        try? logHandle.close()
        try? FileManager.default.removeItem(at: workingDirectory)
    }

    deinit {
        if process.isRunning {
            process.terminate()
        }

        try? logHandle.close()
        try? FileManager.default.removeItem(at: workingDirectory)
    }

    private static func resolveAnvilBinaryPath(misePath: String, sourceRoot: String) throws -> String {
        func run(_ arguments: [String]) throws -> String {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: misePath)
            process.arguments = arguments
            process.environment = MiseTool.processEnvironment

            let outputPipe = Pipe()
            let errorPipe = Pipe()
            process.standardOutput = outputPipe
            process.standardError = errorPipe

            do {
                try process.run()
            } catch {
                throw EthereumLaunchError(
                    description: "failed to run mise \(arguments.joined(separator: " ")): \(error.localizedDescription)"
                )
            }

            process.waitUntilExit()

            let output = String(
                data: outputPipe.fileHandleForReading.readDataToEndOfFile(),
                encoding: .utf8
            )?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let errorOutput = String(
                data: errorPipe.fileHandleForReading.readDataToEndOfFile(),
                encoding: .utf8
            )?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

            guard process.terminationStatus == 0 else {
                let details = errorOutput.isEmpty ? output : errorOutput
                throw EthereumLaunchError(
                    description: "mise \(arguments.joined(separator: " ")) failed (status \(process.terminationStatus)): \(details)"
                )
            }

            return output
        }

        _ = try run(["-C", sourceRoot, "x", "foundry", "--", "true"])
        let path = try run(["-C", sourceRoot, "which", "anvil"])

        guard !path.isEmpty else {
            throw EthereumLaunchError(description: "mise returned an empty path for anvil")
        }

        return path
    }

    private func waitUntilReady() async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(30))
        while ContinuousClock.now < deadline {
            // swiftlint:disable:next unused_optional_binding
            if let _: String = try? await rpc.call(method: "eth_blockNumber", params: [String]()) {
                return
            }

            try? await Task.sleep(for: .milliseconds(200))
        }

        let logURL = workingDirectory.appendingPathComponent("anvil.log")
        let log = (try? String(contentsOf: logURL, encoding: .utf8)) ?? "(no log)"
        let status = process.isRunning ? "still running" : "exited with status \(process.terminationStatus)"
        throw EthereumLaunchError(
            description: "anvil never became ready on \(endpoint) within 30s (\(status)). Log tail:\n\(log.suffix(2000))"
        )
    }

    /// Sets an account's native-token balance using Anvil's cheat-code RPC method.
    public func setBalance(_ address: EthereumAddress, wei: BigUInt) async throws {
        let _: Bool? = try? await rpc.call(
            method: "anvil_setBalance",
            params: [address.string, "0x" + String(wei, radix: 16)]
        )

        let actual = try await nativeBalance(of: address)
        guard actual == wei else {
            throw EthereumLaunchError(
                description: "anvil_setBalance(\(address.string), \(wei)) didn't take effect — balance is \(actual)"
            )
        }
    }

    /// The node's latest block number.
    public func blockNumber() async throws -> UInt64 {
        let hex: String = try await rpc.call(method: "eth_blockNumber", params: [String]())
        let digits = hex.hasPrefix("0x") ? String(hex.dropFirst(2)) : hex

        guard let number = UInt64(digits, radix: 16) else {
            throw BlockchainClientError.decodingFailed(reason: "invalid block number: \(hex)")
        }

        return number
    }

    /// Mines `count` empty blocks with Anvil's `anvil_mine` cheat code.
    public func mine(blocks count: UInt64) async throws {
        let before = try await blockNumber()
        let _: String? = try? await rpc.call(method: "anvil_mine", params: ["0x" + String(count, radix: 16)])

        guard try await blockNumber() >= before + count else {
            throw EthereumLaunchError(description: "anvil_mine(\(count)) didn't take effect")
        }
    }

    /// Reads an account's native-token balance.
    public func nativeBalance(of address: EthereumAddress) async throws -> BigUInt {
        let hex: String = try await rpc.call(
            method: "eth_getBalance",
            params: [address.string, "latest"]
        )

        let body = hex.hasPrefix("0x") ? String(hex.dropFirst(2)) : hex

        guard let balance = BigUInt(body, radix: 16) else {
            throw BlockchainClientError.decodingFailed(reason: "invalid quantity hex: \(hex)")
        }

        return balance
    }

    /// Returns an account's pending transaction count.
    public func transactionCount(of address: EthereumAddress) async throws -> BigUInt {
        let hex: String = try await rpc.call(
            method: "eth_getTransactionCount",
            params: [address.string, "pending"]
        )

        let body = hex.hasPrefix("0x") ? String(hex.dropFirst(2)) : hex

        guard let count = BigUInt(body, radix: 16) else {
            throw BlockchainClientError.decodingFailed(reason: "invalid quantity hex: \(hex)")
        }

        return count
    }

    /// Returns Anvil's current gas price in wei.
    public func gasPrice() async throws -> BigUInt {
        let hex: String = try await rpc.call(method: "eth_gasPrice", params: [String]())
        let body = hex.hasPrefix("0x") ? String(hex.dropFirst(2)) : hex

        guard let price = BigUInt(body, radix: 16) else {
            throw BlockchainClientError.decodingFailed(reason: "invalid quantity hex: \(hex)")
        }

        return price
    }

    /// Sends and confirms a legacy transaction using the supplied signer.
    ///
    /// This keeps nonce lookup, signing, broadcast, and confirmation in the
    /// node fixture so integration and UI tests exercise the same transaction
    /// path without duplicating JSON-RPC plumbing.
    public func send(
        signer: EthereumPKeySigner,
        to: EthereumAddress?,
        value: BigUInt = 0,
        data: Data = Data(),
        gasLimit: BigUInt
    ) async throws -> String {
        let sender = try signer.address()

        let transaction = UnsignedLegacyTransaction(
            nonce: try await transactionCount(of: sender),
            gasPrice: try await gasPrice(),
            gasLimit: gasLimit,
            to: to,
            value: value,
            data: data,
            chainId: chainId
        )

        let signed = try await signer.sign(transaction: transaction.signingData)
        let hash = try await EthereumRPCClient(endpoint: endpoint, chainId: chainId).broadcast(signed)
        let receipt = try await waitForReceipt(hash)

        guard receipt.status == "0x1" else {
            throw EthereumLaunchError(description: "transaction \(hash) reverted")
        }

        return hash
    }

    /// Mints an ERC-20 token through a test token's `mint(address,uint256)` method.
    /// The token contract is intentionally supplied by the caller so this works
    /// with any test ERC-20 fixture, not a hard-coded deployment.
    public func faucetERC20(
        signer: EthereumPKeySigner,
        token: EthereumAddress,
        recipient: EthereumAddress,
        amount: BigUInt
    ) async throws -> String {
        try await send(
            signer: signer,
            to: token,
            data: EthereumABI.encodeCall(
                selector: EthereumABI.selector("mint(address,uint256)"),
                parameters: [.address(recipient), .uint256(amount)]
            ),
            gasLimit: 100_000
        )
    }

    /// Polls until Anvil returns a receipt for the transaction.
    public func waitForReceipt(_ transactionHash: String) async throws -> TransactionReceipt {
        let deadline = ContinuousClock.now.advanced(by: .seconds(10))
        while ContinuousClock.now < deadline {
            if let receipt: TransactionReceipt = try? await rpc.call(
                method: "eth_getTransactionReceipt",
                params: [transactionHash]
            ) {
                return receipt
            }

            try? await Task.sleep(for: .milliseconds(100))
        }

        throw EthereumLaunchError(description: "no receipt for \(transactionHash) within 10s")
    }
}

private struct AnvilRPCClient {
    private let endpoint: URL

    init(endpoint: URL) {
        self.endpoint = endpoint
    }

    func call<Params: Encodable, Result: Decodable>(
        method: String,
        params: Params
    ) async throws -> Result {
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(Request(method: method, params: params))
        request.timeoutInterval = 10

        let (data, response) = try await URLSession.shared.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse, (200..<300).contains(httpResponse.statusCode) else {
            throw EthereumLaunchError(description: "unexpected HTTP response while calling \(method)")
        }

        let envelope = try JSONDecoder().decode(Response<Result>.self, from: data)

        if let error = envelope.error {
            throw EthereumLaunchError(description: "\(method) failed: \(error.message)")
        }

        guard let result = envelope.result else {
            throw EthereumLaunchError(description: "\(method) returned no result")
        }

        return result
    }

    private struct Request<Params: Encodable>: Encodable {
        let jsonrpc = "2.0"
        let id = 1
        let method: String
        let params: Params
    }

    private struct Response<Result: Decodable>: Decodable {
        let result: Result?
        let error: ErrorPayload?
    }

    private struct ErrorPayload: Decodable {
        let message: String
    }
}

#endif
