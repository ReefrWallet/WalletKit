//
//  EthereumRPCClient.swift
//  WalletKit
//
//  Created by Andrey Yurkevich on 17/08/2026.
//  Copyright © 2026 Reefr Wallet. All rights reserved.
//

import BigInt
import Foundation

/// A client for an Ethereum JSON-RPC node — native-token balance,
/// arbitrary read-only contract calls, and broadcasting an already-signed
/// transaction. Pairs with ``EthereumPKeySigner``/``EthereumTrezorSigner``,
/// which produce the signed transaction bytes ``broadcast(_:)`` sends;
/// this client builds no transactions of its own.
public struct EthereumRPCClient: Sendable {
    /// The EVM chain ID this client's endpoint is expected to serve —
    /// descriptive only. Unlike signing, reading a balance or broadcasting
    /// to the wrong network is a configuration/UX concern, not a replay-
    /// protection one, so this isn't enforced against responses.
    public let chainId: UInt64

    let rpc: JSONRPCClient

    /// Creates a client for the node at `endpoint`.
    ///
    /// - Parameters:
    ///   - endpoint: The node's JSON-RPC HTTPS endpoint.
    ///   - chainId: The EVM chain ID this endpoint is expected to serve.
    ///     Defaults to `1` (Ethereum mainnet).
    ///   - session: The `URLSession` to issue requests on. Defaults to
    ///     `.shared`.
    public init(endpoint: URL, chainId: UInt64 = 1, session: URLSession = .shared) {
        self.chainId = chainId
        rpc = JSONRPCClient(endpoint: endpoint, session: session)
    }

    /// Broadcasts an already-signed transaction — `eth_sendRawTransaction`.
    ///
    /// - Parameter signedTransaction: The RLP-encoded signed transaction,
    ///   e.g. from ``EthereumPKeySigner/sign(transaction:)``.
    /// - Returns: The transaction hash.
    /// - Throws: ``BlockchainClientError`` on a transport, RPC, or
    ///   decoding failure.
    public func broadcast(_ signedTransaction: Data) async throws -> String {
        do {
            return try await rpc.call(method: "eth_sendRawTransaction", params: [signedTransaction.hexEncoded])
        } catch let BlockchainClientError.rpcError(_, message)
            where message.localizedCaseInsensitiveContains("already known") {
            // A 429/503 retry can land on this after the first attempt
            // actually succeeded server-side. The transaction hash is
            // deterministic from the signed bytes regardless of what the
            // node's response says, so recover it locally instead of
            // surfacing a false failure.
            return EthereumABI.keccak256(signedTransaction).hexEncoded
        }
    }

    /// Executes a read-only contract call against `address` — the
    /// general "execute a smart contract" entry point.
    /// ``erc20Balance(token:owner:)`` is a worked example built on this; a
    /// caller with a different contract computes its own call data via
    /// ``EthereumABI`` and calls this directly.
    ///
    /// - Parameters:
    ///   - address: The contract address to call.
    ///   - data: The ABI-encoded call data (selector + parameters).
    /// - Returns: The raw return data.
    /// - Throws: ``BlockchainClientError`` on a transport, RPC, or
    ///   decoding failure.
    public func call(to address: EthereumAddress, data: Data) async throws -> Data {
        let params = EthCallParams(to: address.string, data: data.hexEncoded)
        let hex: String = try await rpc.call(method: "eth_call", params: params)
        return try Data(hexString: hex)
    }

    /// Reads `address`'s native-token (ETH) balance, in wei.
    ///
    /// - Parameter address: The address to read the balance of.
    /// - Returns: The balance, in wei.
    /// - Throws: ``BlockchainClientError`` on a transport, RPC, or
    ///   decoding failure.
    public func nativeBalance(of address: EthereumAddress) async throws -> BigUInt {
        // `eth_getBalance` returns Ethereum's "Quantity" hex encoding —
        // minimal digits, no leading zeros, so (unlike "Data" hex —
        // addresses, calldata, raw tx — which is always byte-aligned) an
        // odd digit count is valid (e.g. "0x1" for 1 wei). `parseQuantity`
        // handles this format.
        let hex: String = try await rpc.call(method: "eth_getBalance", params: [address.string, "latest"])
        return try parseQuantity(hex)
    }

    /// Reads `address`'s current nonce — the number of transactions it has
    /// sent, i.e. the nonce to use for its next transaction.
    ///
    /// - Parameter address: The address to read the nonce of.
    /// - Returns: The nonce.
    /// - Throws: ``BlockchainClientError`` on a transport, RPC, or
    ///   decoding failure.
    public func nonce(of address: EthereumAddress) async throws -> UInt64 {
        let hex: String = try await rpc.call(method: "eth_getTransactionCount", params: [address.string, "latest"])
        let value = try parseQuantity(hex)
        guard let nonce = UInt64(exactly: value) else {
            throw BlockchainClientError.decodingFailed(reason: "nonce overflows UInt64: \(hex)")
        }

        return nonce
    }

    /// Returns current fee rates. Fetches `eth_gasPrice`,
    /// `eth_maxPriorityFeePerGas` and the latest block's `baseFeePerGas`
    /// concurrently; ``EthereumFeeRates/maxFeePerGas`` is
    /// `baseFee × 2 + maxPriorityFeePerGas`.
    ///
    /// - Throws: ``BlockchainClientError`` on a transport, RPC, or
    ///   decoding failure.
    public func feeRates() async throws -> EthereumFeeRates {
        async let gasPriceHex: String = rpc.call(method: "eth_gasPrice", params: [String]())
        async let priorityFeeHex: String = rpc.call(method: "eth_maxPriorityFeePerGas", params: [String]())
        async let fetchedBlock: LatestBlock = rpc.call(method: "eth_getBlockByNumber", params: LatestBlockParams())

        let gasPrice = try parseQuantity(try await gasPriceHex)
        let priorityFee = try parseQuantity(try await priorityFeeHex)
        let baseFee = try parseQuantity((try await fetchedBlock).baseFeePerGas ?? "0x0")

        return EthereumFeeRates(
            gasPrice: gasPrice,
            maxFeePerGas: baseFee * 2 + priorityFee,
            maxPriorityFeePerGas: priorityFee
        )
    }

    /// Returns the node's `eth_estimateGas` for the described call.
    ///
    /// - Parameters:
    ///   - from: The sender, or `nil` for the node's default.
    ///   - to: The call destination, or `nil` for contract creation.
    ///   - value: Native value in wei.
    ///   - data: Call data or creation bytecode.
    /// - Throws: ``BlockchainClientError`` on a transport, RPC, or
    ///   decoding failure (including a reverting call).
    public func estimateGas(
        from: EthereumAddress?,
        to: EthereumAddress?,
        value: BigUInt? = nil,
        data: Data? = nil
    ) async throws -> BigUInt {
        let params = EstimateGasParams(
            from: from?.string,
            to: to?.string,
            value: value.map { "0x" + String($0, radix: 16) },
            data: data.map(\.hexEncoded)
        )

        let gasLimitHex: String = try await rpc.call(method: "eth_estimateGas", params: params)
        return try parseQuantity(gasLimitHex)
    }

    /// Executes an arbitrary JSON-RPC method with raw, already
    /// JSON-encoded `params`, returning the raw `result` JSON verbatim —
    /// the passthrough surface a dapp bridge uses for read-only methods
    /// it doesn't otherwise model (`eth_blockNumber`, `eth_getLogs`, ...).
    ///
    /// - Parameters:
    ///   - method: The JSON-RPC method name.
    ///   - params: The method's `params` value, already JSON-encoded
    ///     (e.g. a JSON array literal).
    /// - Returns: The raw `result` JSON.
    /// - Throws: ``BlockchainClientError`` on a transport, RPC, or
    ///   decoding failure.
    public func request(method: String, params: Data) async throws -> Data {
        try await rpc.call(method: method, params: params)
    }

    // MARK: - Private helpers

    /// Parses Ethereum's "Quantity" hex encoding — a `0x`-prefixed,
    /// minimal-digit hex integer (odd digit count is valid, e.g. `"0x1"` for
    /// 1 wei). Unlike "Data" hex (addresses, calldata), a Quantity is parsed
    /// as a plain big integer, not through `Data(hexString:)`.
    private func parseQuantity(_ hex: String) throws -> BigUInt {
        let body = hex.hasPrefix("0x") ? String(hex.dropFirst(2)) : hex
        guard let value = BigUInt(body, radix: 16) else {
            throw BlockchainClientError.decodingFailed(reason: "invalid quantity hex: \(hex)")
        }

        return value
    }
}
