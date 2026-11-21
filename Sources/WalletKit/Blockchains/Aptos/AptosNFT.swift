//
//  AptosNFT.swift
//  WalletKit
//
//  Copyright © 2026 Reefr Wallet. All rights reserved.
//

import BigInt
import Foundation

// MARK: - Listing

extension AptosClient: NFTListing {
    static let nftPageSize = 100

    /// The indexer query behind ``ownedNFTs(_:cursor:minContextSlot:)``.
    static let ownedNFTsQuery = """
        query OwnedNFTs($owner: String!, $limit: Int!, $offset: Int!) {
          current_token_ownerships_v2(
            where: {
              owner_address: {_eq: $owner},
              _or: [
                {token_standard: {_eq: "v2"}, _or: [{is_fungible_v2: {_eq: false}}, {is_fungible_v2: {_is_null: true}}]},
                {token_standard: {_eq: "v1"}, amount: {_gt: "0"}}
              ]
            },
            order_by: [{token_data_id: asc}, {property_version_v1: asc}],
            limit: $limit,
            offset: $offset
          ) {
            amount token_data_id token_standard is_soulbound_v2 non_transferrable_by_owner last_transaction_version
            current_token_data {
              token_name token_uri collection_id
              current_collection { collection_name }
            }
          }
          processor_status(where: {processor: {_eq: "token_v2_processor"}}) {
            last_success_version last_transaction_timestamp
          }
        }
        """

    /// Lists one page of `owner`'s Token V2 objects (any amount: V2 rows have
    /// amount 0) and Token V1 holdings (amount > 0). V1 tokens, soulbound V2
    /// tokens and ones the owner can't transfer are listed with
    /// `isTransferable == false`. The position is the token processor's
    /// status from the same request.
    public func ownedNFTs(_ owner: String, cursor: String?, minContextSlot: UInt64?) async throws -> NFTPage {
        let owner = try AptosAddress(chainString: owner)
        let offset = cursor.flatMap(Int.init) ?? 0
        let response: AptosOwnedNFTsResponse = try await graphQL(
            Self.ownedNFTsQuery,
            variables: ["owner": owner.longString, "limit": Self.nftPageSize, "offset": offset]
        )

        return Self.nftPage(response, offset: offset)
    }

    static func nftPage(_ response: AptosOwnedNFTsResponse, offset: Int) -> NFTPage {
        let items = response.ownerships.compactMap { row -> OwnedNFT? in
            let isV2 = row.tokenStandard == "v2"
            guard isV2 || row.tokenStandard == "v1" else {
                return nil
            }

            let quantity = isV2 ? BigUInt(1) : BigUInt(row.amount.description) ?? 1
            let isTransferable = isV2 && row.isSoulbound != true && row.isNonTransferable != true

            return OwnedNFT(
                collectionName: row.tokenData?.collection?.name,
                metadataURI: row.tokenData?.tokenURI.flatMap { $0.isEmpty ? nil : $0 },
                name: row.tokenData?.tokenName,
                quantity: quantity,
                reference: NFTReference(
                    collection: row.tokenData?.collectionId ?? "",
                    isTransferable: isTransferable,
                    standard: isV2 ? .aptosTokenV2 : .aptosTokenV1,
                    tokenId: row.tokenDataId
                ),
                version: UInt64(row.lastTransactionVersion.description)
            )
        }

        let status = response.processorStatus.first
        let position = status.flatMap { status in
            UInt64(status.lastSuccessVersion.description).map {
                NFTSnapshotPosition.aptos(
                    processorVersion: $0,
                    processorTimestamp: status.lastTransactionTimestamp.flatMap(Self.indexerDate)
                )
            }
        }

        let isLastPage = response.ownerships.count < nftPageSize
        return NFTPage(cursor: isLastPage ? nil : String(offset + nftPageSize), items: items, position: position)
    }

    /// Parses the indexer's UTC timestamps (`2026-11-21T10:00:00` or with
    /// fractional seconds, no zone).
    static func indexerDate(_ string: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        formatter.timeZone = TimeZone(identifier: "UTC")
        let trimmed = string.split(separator: ".").first.map(String.init) ?? string
        formatter.formatOptions = [.withFullDate, .withTime, .withColonSeparatorInTime, .withDashSeparatorInDate]
        return formatter.date(from: trimmed.replacingOccurrences(of: "Z", with: ""))
    }
}

struct AptosOwnedNFTsResponse: Decodable {
    struct Collection: Decodable {
        let name: String?

        enum CodingKeys: String, CodingKey {
            case name = "collection_name"
        }
    }

    struct Ownership: Decodable {
        let amount: AptosIndexerNumber
        let isNonTransferable: Bool?
        let isSoulbound: Bool?
        let lastTransactionVersion: AptosIndexerNumber
        let tokenData: TokenData?
        let tokenDataId: String
        let tokenStandard: String

        enum CodingKeys: String, CodingKey {
            case amount
            case isNonTransferable = "non_transferrable_by_owner"
            case isSoulbound = "is_soulbound_v2"
            case lastTransactionVersion = "last_transaction_version"
            case tokenData = "current_token_data"
            case tokenDataId = "token_data_id"
            case tokenStandard = "token_standard"
        }
    }

    struct ProcessorStatus: Decodable {
        let lastSuccessVersion: AptosIndexerNumber
        let lastTransactionTimestamp: String?

        enum CodingKeys: String, CodingKey {
            case lastSuccessVersion = "last_success_version"
            case lastTransactionTimestamp = "last_transaction_timestamp"
        }
    }

    struct TokenData: Decodable {
        let collection: Collection?
        let collectionId: String?
        let tokenName: String?
        let tokenURI: String?

        enum CodingKeys: String, CodingKey {
            case collection = "current_collection"
            case collectionId = "collection_id"
            case tokenName = "token_name"
            case tokenURI = "token_uri"
        }
    }

    let ownerships: [Ownership]
    let processorStatus: [ProcessorStatus]

    enum CodingKeys: String, CodingKey {
        case ownerships = "current_token_ownerships_v2"
        case processorStatus = "processor_status"
    }
}

// MARK: - Transfer

public extension AptosEntryFunction {
    /// `0x1::object::transfer<0x4::token::Token>(object, to)` for a Digital
    /// Asset.
    static func tokenObjectTransfer(object: AptosAddress, to recipient: AptosAddress) throws -> AptosEntryFunction {
        let framework = try AptosAddress(string: "0x1")
        let tokenModule = try AptosAddress(string: "0x4")

        return AptosEntryFunction(
            module: framework,
            moduleName: "object",
            functionName: "transfer",
            typeArguments: [.structTag(address: tokenModule.rawBytes, module: "token", name: "Token", typeArguments: [])],
            arguments: [object.rawBytes, recipient.rawBytes]
        )
    }
}

extension AptosTransactionBuilder: NFTTransactionBuilding {
    /// Transfers a Token V2 object with `0x1::object::transfer`.
    public func buildNFTTransfer(
        sender: String,
        recipient: String,
        nft: NFTReference,
        quantity: BigUInt,
        options: [BlockchainTransactionBuilderOptions]
    ) async throws -> Data {
        try requireTransferable(nft, standards: [.aptosTokenV2])

        return try await buildEntryFunction(
            sender: AptosAddress(chainString: sender),
            payload: .tokenObjectTransfer(
                object: AptosAddress(chainString: nft.tokenId),
                to: AptosAddress(chainString: recipient)
            ),
            options: options
        )
    }
}
