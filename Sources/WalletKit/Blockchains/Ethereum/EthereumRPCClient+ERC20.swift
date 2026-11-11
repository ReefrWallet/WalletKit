//
//  EthereumRPCClient+ERC20.swift
//  WalletKit
//
//  Created by Andrey Yurkevich on 17/08/2026.
//  Copyright © 2026 Reefr Wallet. All rights reserved.
//

import BigInt
import Foundation

public extension EthereumRPCClient {
    /// Reads an ERC-20 `token`'s balance for `owner` — `balanceOf(address)`.
    ///
    /// - Parameters:
    ///   - token: The ERC-20 contract address.
    ///   - owner: The account to read the balance of.
    /// - Returns: The balance, in the token's smallest unit.
    /// - Throws: ``BlockchainClientError`` on a transport, RPC, or
    ///   decoding failure.
    func erc20Balance(
        token: EthereumAddress,
        owner: EthereumAddress
    ) async throws -> BigUInt {
        let data = EthereumABI.encodeCall(
            selector: EthereumABI.selector("balanceOf(address)"),
            parameters: [.address(owner)]
        )

        let result = try await call(to: token, data: data)

        guard let word = EthereumABI.words(result).first else {
            throw BlockchainClientError.decodingFailed(reason: "empty balanceOf(address) response")
        }

        return EthereumABI.decodeUInt256(word)
    }

    /// Reads many ERC-20 `allowance(owner, spender)` values using Multicall3 `eth_call`s of up to
    /// `chunkSize` pairs each, falling back to a JSON-RPC batch per chunk when the aggregate
    /// contract is unavailable.
    ///
    /// - Parameters:
    ///   - pairs: The token and spender of each allowance.
    ///   - owner: The account that granted the allowances.
    ///   - chunkSize: The most pairs per request.
    /// - Returns: The allowance of each pair, in order; `nil` where the call failed or returned
    ///   no value.
    /// - Throws: ``BlockchainClientError`` if a chunk fails on both paths.
    func erc20Allowances(
        pairs: [(token: EthereumAddress, spender: EthereumAddress)],
        owner: EthereumAddress,
        chunkSize: Int = 200
    ) async throws -> [BigUInt?] {
        let calls = pairs.map { pair in
            (
                target: pair.token,
                data: EthereumABI.encodeCall(
                    selector: EthereumABI.selector("allowance(address,address)"),
                    parameters: [.address(owner), .address(pair.spender)]
                )
            )
        }

        return try await batchedCalls(calls, chunkSize: chunkSize).map { data in
            data.flatMap { $0.count >= 32 ? EthereumABI.words($0).first.map(EthereumABI.decodeUInt256) : nil }
        }
    }

    /// Reads the `name()`, `symbol()` and `decimals()` of many ERC-20 `tokens` using Multicall3
    /// `eth_call`s of up to `chunkSize` calls each, falling back to a JSON-RPC batch per chunk when
    /// the aggregate contract is unavailable.
    ///
    /// - Parameters:
    ///   - tokens: The ERC-20 contract addresses.
    ///   - chunkSize: The most calls per request; each token takes three.
    /// - Returns: The metadata of each token, in order; `nil` where any of its three calls failed
    ///   or returned something undecodable.
    /// - Throws: ``BlockchainClientError`` if a chunk fails on both paths.
    func erc20TokenInfos(tokens: [EthereumAddress], chunkSize: Int = 198) async throws -> [TokenInfo?] {
        let selectors = ["name()", "symbol()", "decimals()"].map { EthereumABI.selector($0) }
        let calls = tokens.flatMap { token in
            selectors.map { (target: token, data: EthereumABI.encodeCall(selector: $0)) }
        }

        // Whole tokens per chunk, so a token's three calls are never split.
        let results = try await batchedCalls(calls, chunkSize: max(3, chunkSize / 3 * 3))

        return tokens.indices.map { index in
            let base = index * 3

            guard let nameData = results[base], let symbolData = results[base + 1],
                  let decimalsData = results[base + 2],
                  let name = try? EthereumABI.decodeString(nameData),
                  let symbol = try? EthereumABI.decodeString(symbolData),
                  let word = EthereumABI.words(decimalsData).first,
                  let decimals = UInt8(exactly: EthereumABI.decodeUInt256(word)) else {
                return nil
            }

            return TokenInfo(decimals: decimals, name: name, isNative: false, symbol: symbol)
        }
    }

    /// Reads multiple ERC-20 balances using one Multicall3 `eth_call`, falling
    /// back to a JSON-RPC batch when the aggregate contract is unavailable.
    func erc20Balances(
        tokens: [EthereumAddress],
        owner: EthereumAddress
    ) async throws -> [String: BigUInt] {
        guard !tokens.isEmpty else {
            return [:]
        }

        let callData = tokens.map { _ in
            EthereumABI.encodeCall(
                selector: EthereumABI.selector("balanceOf(address)"),
                parameters: [.address(owner)]
            )
        }

        let calls = zip(tokens, callData).map { (target: $0.0, allowFailure: true, callData: $0.1) }

        let multicall = try multicall3Address()

        do {
            let result = try await call(
                to: multicall,
                data: EthereumABI.encodeAggregate3(calls)
            )

            let aggregateResults = try EthereumABI.decodeAggregate3(result)

            guard aggregateResults.count == tokens.count else {
                throw BlockchainClientError.decodingFailed(reason: "aggregate3 returned an unexpected result count")
            }

            return aggregateResults.enumerated().reduce(into: [:]) { result, item in
                guard item.element.success, let word = EthereumABI.words(item.element.returnData).first,
                      item.element.returnData.count >= 32 else {
                    return
                }

                result[tokens[item.offset].string] = EthereumABI.decodeUInt256(word)
            }
        } catch {
            let params = tokens.map { token in
                EthCallParams(
                    to: token.string,
                    data: EthereumABI.encodeCall(
                        selector: EthereumABI.selector("balanceOf(address)"),
                        parameters: [.address(owner)]
                    ).hexEncoded
                )
            }

            let fallback: [String?] = try await rpc.callBatch(method: "eth_call", params: params)
            return fallback.enumerated().reduce(into: [:]) { result, item in
                guard let value = item.element else {
                    return
                }

                let hex = value.hasPrefix("0x") ? String(value.dropFirst(2)) : value

                guard let amount = BigUInt(hex, radix: 16) else {
                    return
                }

                result[tokens[item.offset].string] = amount
            }
        }
    }

    /// Reads an ERC-20 `token`'s metadata — `name()`, `symbol()`, and
    /// `decimals()`.
    ///
    /// - Parameter token: The ERC-20 contract address.
    /// - Returns: The token's metadata.
    /// - Throws: ``BlockchainClientError`` on a transport, RPC, or
    ///   decoding failure.
    func erc20TokenInfo(token: EthereumAddress) async throws -> TokenInfo {
        async let nameData = call(
            to: token,
            data: EthereumABI.encodeCall(selector: EthereumABI.selector("name()"))
        )

        async let symbolData = call(
            to: token,
            data: EthereumABI.encodeCall(selector: EthereumABI.selector("symbol()"))
        )

        async let decimalsData = call(
            to: token,
            data: EthereumABI.encodeCall(selector: EthereumABI.selector("decimals()"))
        )

        let name = try EthereumABI.decodeString(try await nameData)
        let symbol = try EthereumABI.decodeString(try await symbolData)

        guard let decimalsWord = EthereumABI.words(try await decimalsData).first,
              let decimals = UInt8(exactly: EthereumABI.decodeUInt256(decimalsWord))
                else {
            throw BlockchainClientError.decodingFailed(reason: "empty or invalid decimals() response")
        }

        return TokenInfo(decimals: decimals, name: name, isNative: false, symbol: symbol)
    }
}

private extension EthereumRPCClient {
    /// Runs `eth_call`s in Multicall3 chunks, falling back to a JSON-RPC batch per chunk. A call
    /// that fails or returns no data is `nil`.
    func batchedCalls(
        _ calls: [(target: EthereumAddress, data: Data)],
        chunkSize: Int
    ) async throws -> [Data?] {
        let size = max(1, chunkSize)
        var result: [Data?] = []

        for start in stride(from: 0, to: calls.count, by: size) {
            let chunk = calls[start..<min(start + size, calls.count)]

            do {
                let aggregate = try EthereumABI.decodeAggregate3(
                    await call(
                        to: multicall3Address(),
                        data: EthereumABI.encodeAggregate3(
                            chunk.map { (target: $0.target, allowFailure: true, callData: $0.data) }
                        )
                    )
                )

                guard aggregate.count == chunk.count else {
                    throw BlockchainClientError.decodingFailed(reason: "aggregate3 returned an unexpected result count")
                }

                result += aggregate.map { $0.success ? $0.returnData : nil }
            } catch {
                let params = chunk.map { EthCallParams(to: $0.target.string, data: $0.data.hexEncoded) }
                let fallback: [String?] = try await rpc.callBatch(method: "eth_call", params: params)

                result += fallback.map { $0.flatMap { try? Data(hexString: $0) } }
            }
        }

        return result
    }

    func multicall3Address() throws -> EthereumAddress {
        let addresses: [UInt64: String] = [
            728_126_428: "0x32a4f47a74a6810bd0bf861cabab99656a75de9e"
        ]
        let address = addresses[chainId] ?? "0xcA11bde05977b3631167028862bE2a173976CA11"
        return try EthereumAddress(string: address)
    }
}
