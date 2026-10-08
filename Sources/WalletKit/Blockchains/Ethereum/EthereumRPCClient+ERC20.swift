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
    func multicall3Address() throws -> EthereumAddress {
        let addresses: [UInt64: String] = [
            728_126_428: "0x32a4f47a74a6810bd0bf861cabab99656a75de9e"
        ]
        let address = addresses[chainId] ?? "0xcA11bde05977b3631167028862bE2a173976CA11"
        return try EthereumAddress(string: address)
    }
}
