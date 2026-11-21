//
//  NFT.swift
//  WalletKit
//
//  Copyright © 2026 Reefr Wallet. All rights reserved.
//

import BigInt
import Foundation

// MARK: - Standard

/// The token standard of a non-fungible asset.
public enum NFTStandard: String, CaseIterable, Codable, Sendable {
    /// An Aptos Token V1 (`0x3::token`) token. Listed, not transferable.
    case aptosTokenV1
    /// An Aptos Digital Asset (`0x4::token::Token` object).
    case aptosTokenV2
    /// A Cardano native asset with CIP-25 metadata.
    case cardanoCIP25
    /// A Cardano CIP-68 user token (label 222).
    case cardanoCIP68
    /// An ERC-1155 token.
    case erc1155
    /// An ERC-721 token.
    case erc721
    /// A Solana SPL mint with Metaplex Token Metadata.
    case solanaMetaplex
    /// A Sui object with Display metadata.
    case suiObject
}

// MARK: - Reference

/// Identifies a non-fungible asset on its chain.
///
/// | Standard | `collection` | `tokenId` |
/// |---|---|---|
/// | ERC-721, ERC-1155 | Contract address | Decimal token id |
/// | Solana | Collection mint, or empty | Mint address |
/// | Sui | Object type | Object id |
/// | Aptos V2 | Collection id | Token object address |
/// | Aptos V1 | Collection id | Token data id |
/// | Cardano | Policy id | Asset unit (policy id + asset name hex) |
public struct NFTReference: Codable, Hashable, Sendable {
    /// The collection identifier.
    public let collection: String
    /// Whether the owner can transfer the asset with
    /// ``NFTTransactionBuilding/buildNFTTransfer(sender:recipient:nft:quantity:options:)``.
    public let isTransferable: Bool
    /// The asset's token standard.
    public let standard: NFTStandard
    /// The asset identifier within its chain.
    public let tokenId: String

    public init(collection: String, isTransferable: Bool, standard: NFTStandard, tokenId: String) {
        self.collection = collection
        self.isTransferable = isTransferable
        self.standard = standard
        self.tokenId = tokenId
    }
}

// MARK: - Owned NFT

/// A non-fungible asset held by an account.
public struct OwnedNFT: Hashable, Sendable {
    /// The collection's display name, if known.
    public let collectionName: String?
    /// The asset's image URI (`https`, `ipfs` or `data`), if known.
    public let imageURI: String?
    /// The asset's metadata JSON URI, if it has one.
    public let metadataURI: String?
    /// The asset's display name, if known.
    public let name: String?
    /// The Move type of a Sui object, if this is one.
    public let objectType: String?
    /// The held quantity (1 for unique assets).
    public let quantity: BigUInt
    /// The asset's identity.
    public let reference: NFTReference
    /// The version the listing read: a Sui object version or an Aptos
    /// ownership row's `last_transaction_version`.
    public let version: UInt64?

    public init(
        collectionName: String? = nil,
        imageURI: String? = nil,
        metadataURI: String? = nil,
        name: String? = nil,
        objectType: String? = nil,
        quantity: BigUInt = 1,
        reference: NFTReference,
        version: UInt64? = nil
    ) {
        self.collectionName = collectionName
        self.imageURI = imageURI
        self.metadataURI = metadataURI
        self.name = name
        self.objectType = objectType
        self.quantity = quantity
        self.reference = reference
        self.version = version
    }
}

// MARK: - Page

/// The chain position a listing page was read at, taken from the same
/// response as its items.
public enum NFTSnapshotPosition: Hashable, Sendable {
    /// Aptos: `processor_status.last_success_version` and
    /// `last_transaction_timestamp` of the token processor.
    case aptos(processorVersion: UInt64, processorTimestamp: Date?)
    /// Cardano: the UTxOs (`txHash#index`) the holdings came from.
    case cardano(outpoints: Set<String>)
    /// Solana: the response's `context.slot`.
    case solana(slot: UInt64)
    /// Sui: the checkpoint and epoch reported with the response, if any.
    case sui(checkpoint: UInt64?, epoch: UInt64?)
}

/// One page of an account's NFTs.
public struct NFTPage: Sendable {
    /// The cursor for the next page, or `nil` when the listing is complete.
    public let cursor: String?
    /// The NFTs on this page.
    public let items: [OwnedNFT]
    /// The chain position this page was read at.
    public let position: NFTSnapshotPosition?

    public init(cursor: String?, items: [OwnedNFT], position: NFTSnapshotPosition?) {
        self.cursor = cursor
        self.items = items
        self.position = position
    }
}

// MARK: - Protocols

/// Lists the NFTs an account holds.
public protocol NFTListing: Sendable {
    /// Returns one page of `owner`'s NFTs.
    ///
    /// - Parameters:
    ///   - owner: The account's address string.
    ///   - cursor: The previous page's ``NFTPage/cursor``, or `nil` for the
    ///     first page.
    ///   - minContextSlot: Solana only: the lowest slot the read may be
    ///     served at. Ignored elsewhere.
    /// - Throws: ``WalletKitError/invalidAddress(reason:)`` or
    ///   ``BlockchainClientError``.
    func ownedNFTs(_ owner: String, cursor: String?, minContextSlot: UInt64?) async throws -> NFTPage
}

/// Builds unsigned NFT transfer transactions.
public protocol NFTTransactionBuilding: Sendable {
    /// Builds unsigned transaction bytes transferring `quantity` of `nft`
    /// from `sender` to `recipient`.
    ///
    /// - Throws: ``BlockchainTransactionBuilderError/unsupportedNFT(reason:)``
    ///   when `nft` isn't transferable by this builder,
    ///   ``WalletKitError/invalidAddress(reason:)``, or
    ///   ``BlockchainClientError``.
    func buildNFTTransfer(
        sender: String,
        recipient: String,
        nft: NFTReference,
        quantity: BigUInt,
        options: [BlockchainTransactionBuilderOptions]
    ) async throws -> Data
}

extension NFTTransactionBuilding {
    func requireTransferable(_ nft: NFTReference, standards: Set<NFTStandard>) throws {
        guard nft.isTransferable, standards.contains(nft.standard) else {
            throw BlockchainTransactionBuilderError.unsupportedNFT(
                reason: "\(nft.standard.rawValue) token \(nft.tokenId) can't be transferred"
            )
        }
    }
}
