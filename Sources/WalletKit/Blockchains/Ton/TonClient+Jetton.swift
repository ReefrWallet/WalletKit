//
//  TonClient+Jetton.swift
//  WalletKit
//
//  Copyright © 2026 Reefr Wallet. All rights reserved.
//

import BigInt
import Foundation

/// The state of a Jetton wallet as its own `get_wallet_data` reports it.
public struct TonJettonWalletData: Equatable, Sendable {
    public let balance: BigUInt
    public let master: TonAddress
    public let owner: TonAddress
}

/// A Jetton the indexer reports `owner` holds.
struct TonIndexedJettonWallet: Equatable {
    let balance: BigUInt
    let master: TonAddress
}

/// Jetton getters, read on-chain: the indexer is for discovery only, so a balance or a wallet that decides
/// where tokens go comes from the contracts themselves.
public extension TonClient {
    /// The Jetton wallet of `owner` under `master`, by the master's `get_wallet_address`. The wallet may not be
    /// deployed yet.
    func jettonWalletAddress(owner: TonAddress, master: TonAddress) async throws -> TonAddress {
        var builder = TonCellBuilder()
        builder.storeAddress(owner)
        let argument = TonBOC.serialize(try builder.build()).base64EncodedString()
        let result = try await runGetMethod(master, method: "get_wallet_address", stack: [["tvm.Slice", argument]])

        guard let cell = result.first, case let .bytes(boc) = cell, let data = Data(base64Encoded: boc) else {
            throw BlockchainClientError.decodingFailed(reason: "unexpected get_wallet_address result")
        }

        return try Self.address(in: try TonBOC.parse(data))
    }

    /// The wallet's data, or `nil` if it is not deployed. Throws if it reports another owner or master than
    /// expected, which a genuine wallet of this master never does.
    func jettonWalletData(
        _ wallet: TonAddress,
        owner: TonAddress,
        master: TonAddress
    ) async throws -> TonJettonWalletData? {
        guard try await accountState(wallet) == .active else {
            return nil
        }

        let result = try await runGetMethod(wallet, method: "get_wallet_data", stack: [])

        guard result.count >= 3, case let .string(text) = result[0],
              let balance = BigUInt(text.dropFirst(2), radix: 16),
              case let .bytes(ownerBoc) = result[1], let ownerData = Data(base64Encoded: ownerBoc),
              case let .bytes(masterBoc) = result[2], let masterData = Data(base64Encoded: masterBoc)
        else {
            throw BlockchainClientError.decodingFailed(reason: "unexpected get_wallet_data result")
        }

        let data = TonJettonWalletData(
            balance: balance,
            master: try Self.address(in: try TonBOC.parse(masterData)),
            owner: try Self.address(in: try TonBOC.parse(ownerData))
        )

        guard data.owner.hash == owner.hash, data.master.hash == master.hash else {
            throw BlockchainClientError.invalidResponse(reason: "the Jetton wallet is not of this owner and master")
        }

        return data
    }

    /// `owner`'s balance of the Jetton `master`, read from its wallet; `0` if the wallet is not deployed.
    func jettonBalance(owner: TonAddress, master: TonAddress) async throws -> BigUInt {
        let wallet = try await jettonWalletAddress(owner: owner, master: master)
        return try await jettonWalletData(wallet, owner: owner, master: master)?.balance ?? 0
    }

    /// The values `method` returns; an exit code other than 0 is an error.
    internal func runGetMethod(_ address: TonAddress, method: String, stack: [[String]]) async throws -> [JSONScalar] {
        let request = RunGetMethodRequest(address: address.rawString, method: method, stack: stack)
        let body = try JSONEncoder().encode(request)
        let result: RunGetMethodResult = try await post("runGetMethod", body: body)

        guard result.exitCode == 0 else {
            throw BlockchainClientError.rpcError(code: result.exitCode, message: "\(method) failed")
        }

        return result.stack.compactMap { $0.count == 2 ? $0[1] : nil }
    }

    /// The `addr_std` held in the first bits of `cell`.
    internal static func address(in cell: TonCell) throws -> TonAddress {
        func bit(_ index: Int) -> Int {
            Int(cell.bits[cell.bits.startIndex + index / 8] >> (7 - index % 8) & 1)
        }

        // addr_std$10, no anycast, 8-bit workchain, 256-bit hash.
        guard cell.bitCount >= 267, bit(0) == 1, bit(1) == 0, bit(2) == 0 else {
            throw BlockchainClientError.decodingFailed(reason: "not an addr_std")
        }

        var byte = 0
        (3 ..< 11).forEach { byte = byte << 1 | bit($0) }
        let hash = Data((0 ..< 32).map { index in
            UInt8((0 ..< 8).reduce(0) { $0 << 1 | bit(11 + index * 8 + $1) })
        })

        return try TonAddress(workchain: Int8(truncatingIfNeeded: byte), hash: hash)
    }

    /// The key ``getAllBalances(_:)`` uses for Gram.
    static var nativeTokenKey: String { "TON" }

    /// The Jettons the indexer lists for `owner`, every page. Any failed page throws.
    internal func indexedJettonWallets(owner: TonAddress) async throws -> [TonIndexedJettonWallet] {
        var wallets: [String: TonIndexedJettonWallet] = [:]
        var offset = 0

        while true {
            let page: JettonWalletsResponse = try await getIndexerPage(
                "jetton/wallets",
                query: [
                    "owner_address": owner.rawString,
                    "limit": String(Self.jettonPageLimit),
                    "offset": String(offset)
                ]
            )

            for wallet in page.jettonWallets {
                guard let balance = BigUInt(wallet.balance) else {
                    throw BlockchainClientError.decodingFailed(reason: "invalid Jetton balance \(wallet.balance)")
                }

                let master = try TonAddress(string: wallet.jetton).bounceable(true)
                wallets[master.rawString] = TonIndexedJettonWallet(
                    balance: balance,
                    master: try TonAddress(
                        workchain: master.workchain,
                        hash: master.hash,
                        isBounceable: true,
                        isTestOnly: network == .testnet
                    )
                )
            }

            guard page.jettonWallets.count == Self.jettonPageLimit else {
                return Array(wallets.values)
            }

            offset += Self.jettonPageLimit
        }
    }

    /// Name, symbol and decimals of `master`. Decimals default to 9 (TEP-64) only when the metadata resolved and
    /// omits them; metadata that is missing or malformed throws, so such a Jetton is not sendable.
    internal func jettonInfo(master: TonAddress) async throws -> TokenInfo {
        let page: JettonMastersResponse = try await getIndexerPage(
            "jetton/masters",
            query: ["address": master.rawString]
        )

        guard let entry = page.metadata.first(where: { (try? TonAddress(string: $0.key))?.hash == master.hash })?.value,
              let info = entry.tokenInfo.first(where: { $0.type == "jetton_masters" }),
              let symbol = info.symbol, !symbol.isEmpty
        else {
            throw BlockchainClientError.decodingFailed(reason: "no metadata for the Jetton \(master.string)")
        }

        let decimals: UInt8

        if let text = info.extra?.decimals {
            guard let value = UInt8(text), value <= 36 else {
                throw BlockchainClientError.decodingFailed(reason: "invalid Jetton decimals \(text)")
            }

            decimals = value
        } else {
            decimals = 9
        }

        return TokenInfo(decimals: decimals, name: info.name ?? symbol, isNative: false, symbol: symbol)
    }

    internal static var jettonPageLimit: Int { 100 }
}

// MARK: - Wire types

extension TonClient {
    struct JettonWalletsResponse: Decodable {
        struct Wallet: Decodable {
            let balance: String
            let jetton: String
        }

        let jettonWallets: [Wallet]

        enum CodingKeys: String, CodingKey {
            case jettonWallets = "jetton_wallets"
        }
    }

    struct JettonMastersResponse: Decodable {
        struct Entry: Decodable {
            let tokenInfo: [Info]

            enum CodingKeys: String, CodingKey {
                case tokenInfo = "token_info"
            }
        }

        struct Info: Decodable {
            struct Extra: Decodable {
                let decimals: String?
            }

            let extra: Extra?
            let name: String?
            let symbol: String?
            let type: String?
        }

        let metadata: [String: Entry]
    }
}
