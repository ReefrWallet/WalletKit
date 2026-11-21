//
//  SolanaNFT.swift
//  WalletKit
//
//  Copyright © 2026 Reefr Wallet. All rights reserved.
//

import BigInt
import Foundation

// MARK: - Metaplex metadata

/// The Metaplex Token Metadata fields an NFT listing needs.
public struct SolanaMetaplexMetadata: Equatable, Sendable {
    /// Token Metadata's `TokenStandard`.
    public enum TokenStandard: UInt8, Sendable {
        case fungible = 2
        case fungibleAsset = 1
        case nonFungible = 0
        case nonFungibleEdition = 3
        case programmableNonFungible = 4
        case programmableNonFungibleEdition = 5
    }

    /// The verified collection mint, if any.
    public let collection: String?
    public let name: String
    public let symbol: String
    /// `nil` for metadata written before token standards existed.
    public let tokenStandard: TokenStandard?
    public let uri: String

    /// Parses a Token Metadata account (Borsh): key, update authority, mint,
    /// `name`/`symbol`/`uri`, seller fee, creators, primary sale, mutability,
    /// edition nonce, token standard and collection. Fields after `uri` are
    /// optional; parsing stops at the first one that doesn't fit.
    public init?(data: Data) {
        var reader = BorshReader(data: data, offset: 1 + 32 + 32)

        guard let name = reader.string(), let symbol = reader.string(), let uri = reader.string() else {
            return nil
        }

        self.name = name
        self.symbol = symbol
        self.uri = uri

        var tokenStandard: TokenStandard?
        var collection: String?

        if reader.skip(2), // seller_fee_basis_points
           let hasCreators = reader.byte(),
           hasCreators == 0 || reader.skipVector(elementSize: 34),
           reader.skip(2), // primary_sale_happened, is_mutable
           let hasNonce = reader.byte(),
           hasNonce == 0 || reader.skip(1),
           let hasStandard = reader.byte() {
            if hasStandard == 1, let raw = reader.byte() {
                tokenStandard = TokenStandard(rawValue: raw)
            }

            if let hasCollection = reader.byte(), hasCollection == 1,
               let verified = reader.byte(),
               let key = reader.bytes(32),
               verified == 1 {
                collection = Base58.encode(key)
            }
        }

        self.collection = collection
        self.tokenStandard = tokenStandard
    }

    /// Whether this metadata describes a non-fungible asset.
    var isNonFungible: Bool {
        switch tokenStandard {
        case .fungible, .fungibleAsset:
            false
        case .nonFungible, .nonFungibleEdition, .programmableNonFungible, .programmableNonFungibleEdition, nil:
            true
        }
    }

    /// Whether ``SolanaTransactionBuilder`` can transfer it; programmable
    /// NFTs need Token Metadata's `TransferV1`.
    var isTransferable: Bool {
        switch tokenStandard {
        case .programmableNonFungible, .programmableNonFungibleEdition:
            false
        default:
            true
        }
    }
}

private struct BorshReader {
    let data: Data
    var offset: Int

    mutating func byte() -> UInt8? {
        bytes(1)?.first
    }

    mutating func bytes(_ count: Int) -> Data? {
        guard count >= 0, offset + count <= data.count else {
            return nil
        }

        defer { offset += count }
        return data.subdata(in: (data.startIndex + offset)..<(data.startIndex + offset + count))
    }

    mutating func skip(_ count: Int) -> Bool {
        bytes(count) != nil
    }

    mutating func skipVector(elementSize: Int) -> Bool {
        guard let count = u32() else {
            return false
        }

        return skip(Int(count) * elementSize)
    }

    mutating func string() -> String? {
        guard let length = u32(), let bytes = bytes(Int(length)) else {
            return nil
        }

        return String(data: bytes, encoding: .utf8)?.trimmingCharacters(in: .controlCharacters)
    }

    mutating func u32() -> UInt32? {
        guard let bytes = bytes(4) else {
            return nil
        }

        return bytes.reversed().reduce(0) { $0 << 8 | UInt32($1) }
    }
}

// MARK: - Listing

extension SolanaRPCClient: NFTListing {
    private struct NFTTokenAccountsParams: Encodable {
        let minContextSlot: UInt64?
        let owner: String
        let programId: String

        private struct Filter: Encodable {
            let programId: String
        }

        private struct Config: Encodable {
            let commitment = "confirmed"
            let encoding = "jsonParsed"
            let minContextSlot: UInt64?
        }

        func encode(to encoder: Encoder) throws {
            var container = encoder.unkeyedContainer()
            try container.encode(owner)
            try container.encode(Filter(programId: programId))
            try container.encode(Config(minContextSlot: minContextSlot))
        }
    }

    /// Lists `owner`'s Token and Token-2022 accounts holding exactly one unit
    /// of a zero-decimal mint with non-fungible Metaplex metadata, in one
    /// page. Programmable NFTs are listed with `isTransferable == false`.
    /// The position is the lower `context.slot` of the two account reads.
    public func ownedNFTs(_ owner: String, cursor: String?, minContextSlot: UInt64?) async throws -> NFTPage {
        let owner = try SolanaAddress(string: owner)
        var slot = UInt64.max
        var mints: [String] = []

        for program in [SolanaProgram.token, SolanaProgram.token2022] {
            let response: ContextValue<[TokenAccountEntry]> = try await rpc.call(
                method: "getTokenAccountsByOwner",
                params: NFTTokenAccountsParams(minContextSlot: minContextSlot, owner: owner.string, programId: program.string)
            )

            slot = min(slot, response.context.slot)
            mints += response.value.compactMap { entry in
                let info = entry.account.data.parsed.info
                return info.tokenAmount.decimals == 0 && info.tokenAmount.amount == "1" ? info.mint : nil
            }
        }

        let metadataAddresses = try mints.map { try SolanaProgram.metadataAddress(mint: SolanaAddress(string: $0)).string }
        let accounts = try await metadataAccounts(metadataAddresses)

        let items = zip(mints, accounts).compactMap { mint, data -> OwnedNFT? in
            guard let data, let metadata = SolanaMetaplexMetadata(data: data), metadata.isNonFungible else {
                return nil
            }

            return OwnedNFT(
                metadataURI: metadata.uri.isEmpty ? nil : metadata.uri,
                name: metadata.name,
                reference: NFTReference(
                    collection: metadata.collection ?? "",
                    isTransferable: metadata.isTransferable,
                    standard: .solanaMetaplex,
                    tokenId: mint
                )
            )
        }

        return NFTPage(cursor: nil, items: items, position: .solana(slot: slot))
    }

    /// Returns `getEpochInfo`'s block height and absolute slot, read together.
    public func blockHeightAndSlot() async throws -> (blockHeight: UInt64, slot: UInt64) {
        struct EpochInfo: Decodable {
            let absoluteSlot: UInt64
            let blockHeight: UInt64
        }

        struct Params: Encodable {
            func encode(to encoder: Encoder) throws {
                var container = encoder.unkeyedContainer()
                try container.encode(["commitment": "confirmed"])
            }
        }

        let info: EpochInfo = try await rpc.call(method: "getEpochInfo", params: Params())
        return (info.blockHeight, info.absoluteSlot)
    }

    private func metadataAccounts(_ addresses: [String]) async throws -> [Data?] {
        var result: [Data?] = []

        for start in stride(from: 0, to: addresses.count, by: 100) {
            let page = Array(addresses[start..<min(start + 100, addresses.count)])
            let response: SolanaRPCValue<[RawAccountEntry?]> = try await rpc.call(
                method: "getMultipleAccounts",
                params: MultipleAccountsParams(addresses: page)
            )

            result += response.value.map { $0?.account.data }
        }

        return result
    }
}

// MARK: - Transfer

extension SolanaTransactionBuilder: NFTTransactionBuilding {
    /// Transfers one unit of a Metaplex NFT mint with
    /// `createIdempotent` + `transferChecked` (decimals 0).
    public func buildNFTTransfer(
        sender: String,
        recipient: String,
        nft: NFTReference,
        quantity: BigUInt,
        options: [BlockchainTransactionBuilderOptions]
    ) async throws -> Data {
        try requireTransferable(nft, standards: [.solanaMetaplex])

        return try await buildTransfer(
            sender: SolanaAddress(string: sender),
            recipient: SolanaAddress(string: recipient),
            amount: 1,
            token: nft.tokenId,
            options: options
        )
    }
}
