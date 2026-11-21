//
//  EthereumNFT.swift
//  WalletKit
//
//  Copyright © 2026 Reefr Wallet. All rights reserved.
//

import BigInt
import Foundation

// MARK: - Transfer

extension EthereumTransactionBuilder: NFTTransactionBuilding {
    /// Builds an ERC-721 `safeTransferFrom(from,to,id)` or ERC-1155
    /// `safeTransferFrom(from,to,id,amount,"")` call to the token contract.
    public func buildNFTTransfer(
        sender: String,
        recipient: String,
        nft: NFTReference,
        quantity: BigUInt,
        options: [BlockchainTransactionBuilderOptions]
    ) async throws -> Data {
        try requireTransferable(nft, standards: [.erc1155, .erc721])

        let sender = try EthereumAddress(string: sender)
        let recipient = try EthereumAddress(string: recipient)

        return try await buildCall(
            sender: sender,
            to: Self.nftContract(nft),
            value: 0,
            data: Self.nftTransferData(from: sender, to: recipient, nft: nft, quantity: quantity),
            options: options
        )
    }

    /// The call data of an NFT transfer.
    ///
    /// - Throws: ``BlockchainTransactionBuilderError/invalidToken(reason:)``
    ///   for a non-decimal token id or a zero ERC-1155 quantity, and
    ///   ``BlockchainTransactionBuilderError/unsupportedNFT(reason:)`` for a
    ///   non-EVM standard.
    public static func nftTransferData(
        from sender: EthereumAddress,
        to recipient: EthereumAddress,
        nft: NFTReference,
        quantity: BigUInt
    ) throws -> Data {
        guard let tokenId = BigUInt(nft.tokenId, radix: 10) else {
            throw BlockchainTransactionBuilderError.invalidToken(reason: "'\(nft.tokenId)' is not a decimal token id")
        }

        switch nft.standard {
        case .erc721:
            return EthereumABI.encodeCall(
                selector: EthereumABI.selector("safeTransferFrom(address,address,uint256)"),
                parameters: [.address(sender), .address(recipient), .uint256(tokenId)]
            )
        case .erc1155:
            guard quantity > 0 else {
                throw BlockchainTransactionBuilderError.invalidToken(reason: "ERC-1155 quantity must be positive")
            }

            return EthereumABI.encodeCall(
                selector: EthereumABI.selector("safeTransferFrom(address,address,uint256,uint256,bytes)"),
                parameters: [.address(sender), .address(recipient), .uint256(tokenId), .uint256(quantity), .bytes(Data())]
            )
        default:
            throw BlockchainTransactionBuilderError.unsupportedNFT(reason: "\(nft.standard.rawValue) isn't an EVM standard")
        }
    }

    /// The contract an NFT transfer calls.
    public static func nftContract(_ nft: NFTReference) throws -> EthereumAddress {
        guard let contract = try? EthereumAddress(string: nft.collection) else {
            throw BlockchainTransactionBuilderError.invalidToken(reason: "'\(nft.collection)' is not a valid Ethereum address")
        }

        return contract
    }
}

// MARK: - Metadata

public extension EthereumRPCClient {
    /// Reads each NFT's metadata URI: ERC-721 `tokenURI(id)` or ERC-1155
    /// `uri(id)`, batched over Multicall3. ERC-1155 `{id}` placeholders are
    /// replaced with the 64-digit lowercase hex id. A failed or empty call
    /// is `nil`.
    func nftMetadataURIs(_ nfts: [NFTReference], chunkSize: Int = 100) async throws -> [String?] {
        let calls: [(target: EthereumAddress, data: Data)?] = nfts.map { nft in
            guard let contract = try? EthereumAddress(string: nft.collection),
                  let tokenId = BigUInt(nft.tokenId, radix: 10)
            else {
                return nil
            }

            let signature = nft.standard == .erc1155 ? "uri(uint256)" : "tokenURI(uint256)"
            return (contract, EthereumABI.encodeCall(selector: EthereumABI.selector(signature), parameters: [.uint256(tokenId)]))
        }

        let results = try await batchedCalls(calls.compactMap(\.self), chunkSize: chunkSize)
        var iterator = results.makeIterator()

        return zip(nfts, calls).map { nft, call in
            guard call != nil,
                  let data = iterator.next() ?? nil,
                  let uri = try? EthereumABI.decodeString(data),
                  !uri.isEmpty
            else {
                return nil
            }

            return Self.substituteNFTId(uri, tokenId: nft.tokenId)
        }
    }

    /// Replaces ERC-1155's `{id}` with the id as 64 lowercase hex digits.
    static func substituteNFTId(_ uri: String, tokenId: String) -> String {
        guard uri.contains("{id}"), let id = BigUInt(tokenId, radix: 10) else {
            return uri
        }

        let hex = String(id, radix: 16)
        return uri.replacingOccurrences(of: "{id}", with: String(repeating: "0", count: max(0, 64 - hex.count)) + hex)
    }
}
