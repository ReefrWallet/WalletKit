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
        try await rpc.call(method: "eth_sendRawTransaction", params: [signedTransaction.hexEncoded])
    }

    /// Executes a read-only contract call against `address` — the
    /// general "execute a smart contract" entry point.
    /// ``erc20Balance(token:owner:)`` and ``latestRoundData(feed:)`` are
    /// two worked examples built on this; a
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

    /// Returns current EIP-1559 fee rates and, when `request` is non-nil,
    /// a per-transaction gas estimate via `eth_estimateGas`.
    ///
    /// Three RPC calls are issued concurrently to fetch the current rates:
    /// - `eth_gasPrice` → ``FeeEstimate/gasPrice``
    /// - `eth_maxPriorityFeePerGas` → ``FeeEstimate/maxPriorityFeePerGas``
    /// - `eth_getBlockByNumber("latest", false)` → `baseFeePerGas`
    ///
    /// ``FeeEstimate/maxFeePerGas`` is `baseFee × 2 + maxPriorityFeePerGas`,
    /// giving 2× headroom over the observed base fee — enough to absorb
    /// several consecutive full blocks without repricing.
    ///
    /// When `request` supplies a `to` address, `eth_estimateGas` is called
    /// for the described call (`from`, `to`, `value`, `data`). The returned
    /// ``FeeEstimate/gasLimit`` is the node's estimate of the gas the
    /// transaction will consume; ``FeeEstimate/estimatedFee`` is
    /// `gasLimit × maxFeePerGas` in wei.
    ///
    /// - Parameter request: A ``FeeEstimateRequest`` describing the
    ///   transaction to estimate, or `nil` for rates-only (no
    ///   ``FeeEstimate/gasLimit`` or ``FeeEstimate/estimatedFee``).
    /// - Returns: A ``FeeEstimate`` with the current EIP-1559 rates, plus
    ///   ``FeeEstimate/gasLimit`` and ``FeeEstimate/estimatedFee`` when
    ///   `request.to` is non-nil.
    /// - Throws: ``BlockchainClientError`` on a transport, RPC, or
    ///   decoding failure.
    public func estimateFee(for request: FeeEstimateRequest<EthereumAddress>?) async throws -> FeeEstimate {
        // Fetch all three rate signals concurrently.
        async let gasPriceHex: String = rpc.call(method: "eth_gasPrice", params: [String]())
        async let priorityFeeHex: String = rpc.call(method: "eth_maxPriorityFeePerGas", params: [String]())
        async let fetchedBlock: LatestBlock = rpc.call(method: "eth_getBlockByNumber", params: LatestBlockParams())

        let gasPrice = try parseQuantity(try await gasPriceHex)
        let priorityFee = try parseQuantity(try await priorityFeeHex)
        let baseFee = try parseQuantity((try await fetchedBlock).baseFeePerGas ?? "0x0")
        let maxFeePerGas = baseFee * 2 + priorityFee

        guard let request, let to = request.to else {
            return FeeEstimate(
                gasPrice: gasPrice,
                maxFeePerGas: maxFeePerGas,
                maxPriorityFeePerGas: priorityFee
            )
        }

        // ETH `value` and ABI `data` are encoded as 0x-prefixed hex strings
        // in the call object, consistent with the rest of the JSON-RPC API.
        let valueHex = request.value.map { "0x" + String($0, radix: 16) }
        let dataHex = request.data.map { $0.hexEncoded }
        let estimateParams = EstimateGasParams(
            from: request.from?.string,
            to: to.string,
            value: valueHex,
            data: dataHex
        )
        let gasLimitHex: String = try await rpc.call(method: "eth_estimateGas", params: estimateParams)
        let gasLimit = try parseQuantity(gasLimitHex)

        return FeeEstimate(
            gasPrice: gasPrice,
            maxFeePerGas: maxFeePerGas,
            maxPriorityFeePerGas: priorityFee,
            gasLimit: gasLimit,
            estimatedFee: gasLimit * maxFeePerGas
        )
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
