//
//  SuiNFT.swift
//  WalletKit
//
//  Copyright © 2026 Reefr Wallet. All rights reserved.
//

import BigInt
import Foundation
import GRPCCore
import SwiftProtobuf
import WalletKitGRPC

// MARK: - Inclusion rule

/// Decides which owned Sui objects an NFT listing shows.
///
/// Display is presentation metadata, not an NFT type check: an object is
/// listed when its Display has a `name` or `image_url` and its type isn't in
/// the framework packages `0x1`, `0x2` or `0x3` (coins, staked SUI, kiosks,
/// caps). A utility object with a Display is still listed.
public enum SuiDisplayableObjectRule {
    private static let frameworkPackages: Set<String> = [
        "0x0000000000000000000000000000000000000000000000000000000000000001",
        "0x0000000000000000000000000000000000000000000000000000000000000002",
        "0x0000000000000000000000000000000000000000000000000000000000000003"
    ]

    /// Whether an object of `objectType` with Display `fields` is listed.
    public static func includes(objectType: String, displayFields: [String: String]) -> Bool {
        guard let canonical = try? MoveTypeTag.canonicalCoinType(objectType),
              let package = canonical.split(separator: "::").first.map(String.init),
              !frameworkPackages.contains(package)
        else {
            return false
        }

        return !(displayFields["name"] ?? "").isEmpty || !(displayFields["image_url"] ?? "").isEmpty
    }

    /// Display output fields as strings; non-string values are dropped.
    static func displayFields(of object: Sui_Rpc_V2_Object) -> [String: String] {
        guard object.hasDisplay, object.display.hasOutput else {
            return [:]
        }

        return object.display.output.structValue.fields.compactMapValues {
            if case let .stringValue(string) = $0.kind {
                return string
            }

            return nil
        }
    }
}

// MARK: - Listing

extension SuiGRPCClient: NFTListing {
    private static let nftReadMask = [
        "object_id", "version", "digest", "object_type", "has_public_transfer", "display", "previous_transaction"
    ]

    /// Lists one page of `owner`'s displayable objects (see
    /// ``SuiDisplayableObjectRule``). The position is the response's
    /// `x-sui-checkpoint-height` and `x-sui-epoch` headers, when the node
    /// sends them.
    public func ownedNFTs(_ owner: String, cursor: String?, minContextSlot: UInt64?) async throws -> NFTPage {
        let owner = try SuiAddress(string: owner)

        return try await withStateServiceClient { client in
            let request = Sui_Rpc_V2_ListOwnedObjectsRequest.with {
                $0.owner = owner.string
                $0.readMask = Google_Protobuf_FieldMask.with { $0.paths = Self.nftReadMask }
                $0.pageSize = 200

                if let cursor, let token = Data(base64Encoded: cursor), !token.isEmpty {
                    $0.pageToken = token
                }
            }

            let (response, checkpoint, epoch) = try await self.rpc(.read) {
                try await client.listOwnedObjects(
                    request: ClientRequest(message: request),
                    options: self.callOptions
                ) { response in
                    (
                        try response.message,
                        Self.header("x-sui-checkpoint-height", in: response.metadata),
                        Self.header("x-sui-epoch", in: response.metadata)
                    )
                }
            }

            let items = response.objects.compactMap { object -> OwnedNFT? in
                let fields = SuiDisplayableObjectRule.displayFields(of: object)
                guard SuiDisplayableObjectRule.includes(objectType: object.objectType, displayFields: fields) else {
                    return nil
                }

                return OwnedNFT(
                    collectionName: fields["collection_name"] ?? fields["project_name"],
                    imageURI: fields["image_url"],
                    name: fields["name"],
                    objectType: object.objectType,
                    reference: NFTReference(
                        collection: object.objectType,
                        isTransferable: object.hasPublicTransfer_p,
                        standard: .suiObject,
                        tokenId: object.objectID
                    ),
                    version: object.version
                )
            }

            return NFTPage(
                cursor: response.nextPageToken.isEmpty ? nil : response.nextPageToken.base64EncodedString(),
                items: items,
                position: .sui(checkpoint: checkpoint, epoch: epoch)
            )
        }
    }

    private static func header(_ name: String, in metadata: Metadata) -> UInt64? {
        for value in metadata[stringValues: name] {
            return UInt64(value)
        }

        return nil
    }
}

// MARK: - Transfer

extension SuiTransactionBuilder: NFTTransactionBuilding {
    /// Transfers a whole object with `TransferObjects([object], recipient)`,
    /// paying gas from the sender's SUI coins. Gas is set by simulation
    /// unless both budget and price are overridden.
    public func buildNFTTransfer( // swiftlint:disable:this function_body_length
        sender: String,
        recipient: String,
        nft: NFTReference,
        quantity: BigUInt,
        options: [BlockchainTransactionBuilderOptions]
    ) async throws -> Data {
        try requireTransferable(nft, standards: [.suiObject])

        let sender = try SuiAddress(string: sender)
        let recipient = try SuiAddress(string: recipient)
        let object = try await client.object(
            id: nft.tokenId,
            readMask: ["object_id", "version", "digest", "owner", "has_public_transfer"]
        )

        guard object.hasPublicTransfer_p,
              object.owner.kind == .address,
              (try? SuiAddress(string: object.owner.address)) == sender
        else {
            throw BlockchainTransactionBuilderError.unsupportedNFT(
                reason: "\(nft.tokenId) isn't a publicly transferable object owned by \(sender.string)"
            )
        }

        let reference = SuiObjectReference(
            objectId: try Data(hexString: object.objectID),
            version: object.version,
            digest: try Base58.decode(object.digest)
        )

        let suiCoins = try await client.ownedCoins(of: sender, coinType: "0x2::sui::SUI")
        let totalSUI = suiCoins.reduce(UInt64(0)) { $0 &+ $1.balance }
        guard totalSUI > 0 else {
            throw BlockchainTransactionBuilderError.insufficientFunds(reason: "\(sender.string) owns no SUI coins for gas")
        }

        let gasOverride = options.suiGasOverride
        let gasPrice: UInt64
        if let price = gasOverride?.price {
            gasPrice = price
        } else {
            gasPrice = try await client.referenceGasPrice()
        }

        func transfer(gas: [SuiCoinObject], budget: UInt64) -> Data {
            UnsignedCoinObjectTransfer(
                sender: sender,
                coinObject: reference,
                recipient: recipient,
                gasPayment: gas.map(\.reference),
                gasOwner: sender,
                gasPrice: gasPrice,
                gasBudget: budget
            ).transactionDataBcs
        }

        let budget: UInt64
        if let overridden = gasOverride?.budget {
            budget = overridden
        } else {
            let simulation = transfer(gas: suiCoins, budget: min(50_000_000, totalSUI))
            budget = try await simulatedBudget(transactionBcs: simulation)
        }

        guard let gas = selectCoins(from: suiCoins, needed: budget) else {
            throw BlockchainTransactionBuilderError.insufficientFunds(
                reason: "need \(budget) MIST gas but \(sender.string) only has \(totalSUI) MIST SUI"
            )
        }

        return transfer(gas: gas, budget: budget)
    }
}
