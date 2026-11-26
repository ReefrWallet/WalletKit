//
//  NFTTests.swift
//  WalletKit
//
//  Copyright © 2026 Reefr Wallet. All rights reserved.
//

import BigInt
import Foundation
import Testing
@testable import WalletKit

private func word(_ value: BigUInt) -> Data {
    let bytes = value.serialize()
    return Data(repeating: 0, count: 32 - bytes.count) + bytes
}

// swiftlint:disable force_try
private let sender = try! EthereumAddress(rawBytes: Data(repeating: 0x11, count: 20))
private let recipient = try! EthereumAddress(rawBytes: Data(repeating: 0x22, count: 20))
// swiftlint:enable force_try

struct EthereumNFTTests {
    @Test func bytesParameterIsEncodedAsOffsetLengthAndPaddedTail() {
        let data = EthereumABI.encodeCall(
            selector: Data([1, 2, 3, 4]),
            parameters: [.uint256(7), .bytes(Data([0xab, 0xcd])), .uint256(9)]
        )

        var expected = Data([1, 2, 3, 4]) + word(7)
        expected += word(96) + word(9)
        expected += word(2) + Data([0xab, 0xcd])
        expected += Data(repeating: 0, count: 30)
        #expect(data == expected)
    }

    @Test func emptyBytesParameterIsOffsetAndZeroLength() {
        let data = EthereumABI.encodeCall(selector: Data([0, 0, 0, 0]), parameters: [.bytes(Data())])
        #expect(data == Data([0, 0, 0, 0]) + word(32) + word(0))
    }

    @Test func erc721TransferCallsThreeArgumentSafeTransferFrom() throws {
        let nft = NFTReference(
            collection: "0x" + String(repeating: "33", count: 20),
            isTransferable: true,
            standard: .erc721,
            tokenId: "42"
        )

        let data = try EthereumTransactionBuilder.nftTransferData(from: sender, to: recipient, nft: nft, quantity: 1)

        #expect(data.prefix(4) == EthereumABI.selector("safeTransferFrom(address,address,uint256)"))
        #expect(data.prefix(4) == Data([0x42, 0x84, 0x2e, 0x0e]))
        #expect(data.count == 4 + 3 * 32)
        #expect(data.suffix(32) == word(42))
    }

    @Test func erc1155TransferCallsFiveArgumentSafeTransferFromWithEmptyBytes() throws {
        let nft = NFTReference(
            collection: "0x" + String(repeating: "33", count: 20),
            isTransferable: true,
            standard: .erc1155,
            tokenId: "5"
        )

        let data = try EthereumTransactionBuilder.nftTransferData(from: sender, to: recipient, nft: nft, quantity: 3)

        #expect(data.prefix(4) == Data([0xf2, 0x42, 0x43, 0x2a]))
        let padding = Data(repeating: 0, count: 12)
        var expected = padding + sender.rawBytes
        expected += padding + recipient.rawBytes
        expected += word(5) + word(3)
        expected += word(160) + word(0)
        #expect(data.dropFirst(4) == expected)
    }

    @Test func erc1155RejectsZeroQuantityAndNonDecimalIds() {
        let zero = NFTReference(
            collection: "0x" + String(repeating: "33", count: 20),
            isTransferable: true,
            standard: .erc1155,
            tokenId: "5"
        )

        let hex = NFTReference(collection: zero.collection, isTransferable: true, standard: .erc721, tokenId: "0x5")

        #expect(throws: BlockchainTransactionBuilderError.self) {
            try EthereumTransactionBuilder.nftTransferData(from: sender, to: recipient, nft: zero, quantity: 0)
        }
        #expect(throws: BlockchainTransactionBuilderError.self) {
            try EthereumTransactionBuilder.nftTransferData(from: sender, to: recipient, nft: hex, quantity: 1)
        }
    }

    @Test func erc1155IdPlaceholderIsSixtyFourLowercaseHexDigits() {
        let uri = EthereumRPCClient.substituteNFTId("https://x/{id}.json", tokenId: "255")
        #expect(uri == "https://x/" + String(repeating: "0", count: 62) + "ff.json")
        #expect(EthereumRPCClient.substituteNFTId("ipfs://a", tokenId: "1") == "ipfs://a")
    }
}

struct SolanaNFTTests {
    private func borshString(_ string: String) -> Data {
        let bytes = Data(string.utf8)
        return withUnsafeBytes(of: UInt32(bytes.count).littleEndian) { Data($0) } + bytes
    }

    private func metadata(tokenStandard: UInt8?, collection: Data?, verified: Bool = true) -> Data {
        var data = Data([4]) + Data(repeating: 1, count: 32) + Data(repeating: 2, count: 32)
        data += borshString("Ape #1") + borshString("APE") + borshString("https://arweave.net/x")
        data += Data([0xf4, 0x01]) // seller fee
        data += Data([1]) + withUnsafeBytes(of: UInt32(1).littleEndian) { Data($0) } + Data(repeating: 9, count: 34)
        data += Data([1, 1]) // primary sale, mutable
        data += Data([1, 254]) // edition nonce
        if let tokenStandard {
            data += Data([1, tokenStandard])
        } else {
            data += Data([0])
        }

        if let collection {
            data += Data([1, verified ? 1 : 0]) + collection
        } else {
            data += Data([0])
        }

        return data
    }

    @Test func parsesNameUriStandardAndVerifiedCollection() throws {
        let collection = Data(repeating: 7, count: 32)
        let parsed = try #require(SolanaMetaplexMetadata(data: metadata(tokenStandard: 0, collection: collection)))

        #expect(parsed.name == "Ape #1")
        #expect(parsed.uri == "https://arweave.net/x")
        #expect(parsed.tokenStandard == .nonFungible)
        #expect(parsed.collection == Base58.encode(collection))
        #expect(parsed.isNonFungible && parsed.isTransferable)
    }

    @Test func programmableNFTIsListedButNotTransferable() throws {
        let parsed = try #require(SolanaMetaplexMetadata(data: metadata(tokenStandard: 4, collection: nil)))
        #expect(parsed.isNonFungible)
        #expect(!parsed.isTransferable)
    }

    @Test func fungibleStandardsAreExcludedAndUnverifiedCollectionIgnored() throws {
        let fungible = try #require(SolanaMetaplexMetadata(data: metadata(tokenStandard: 2, collection: nil)))
        #expect(!fungible.isNonFungible)

        let unverified = try #require(
            SolanaMetaplexMetadata(
                data: metadata(tokenStandard: 0, collection: Data(repeating: 7, count: 32), verified: false)
            )
        )
        #expect(unverified.collection == nil)
    }

    @Test func legacyMetadataWithoutOptionalFieldsParses() throws {
        var data = Data([4]) + Data(repeating: 1, count: 64)
        data += borshString("Old") + borshString("OLD") + borshString("u")
        let parsed = try #require(SolanaMetaplexMetadata(data: data))

        #expect(parsed.tokenStandard == nil)
        #expect(parsed.isNonFungible)
    }
}

struct SuiDisplayableObjectRuleTests {
    private let nftFields = ["name": "Capy", "image_url": "https://x/capy.png"]

    @Test(arguments: [
        "0x2::coin::Coin<0x2::sui::SUI>",
        "0x3::staking_pool::StakedSui",
        "0x2::package::UpgradeCap",
        "0x2::coin::TreasuryCap<0xabc::t::T>",
        "0x2::kiosk::Kiosk",
        "0x0000000000000000000000000000000000000000000000000000000000000002::kiosk::KioskOwnerCap"
    ])
    func frameworkObjectsAreExcludedEvenWithDisplay(objectType: String) {
        #expect(!SuiDisplayableObjectRule.includes(objectType: objectType, displayFields: nftFields))
    }

    @Test func displayableObjectIsIncluded() {
        #expect(SuiDisplayableObjectRule.includes(objectType: "0xabc::capy::Capy", displayFields: nftFields))
        #expect(SuiDisplayableObjectRule.includes(objectType: "0xabc::capy::Capy", displayFields: ["image_url": "x"]))
    }

    @Test func objectWithoutDisplayIsExcluded() {
        #expect(!SuiDisplayableObjectRule.includes(objectType: "0xabc::capy::Capy", displayFields: [:]))
        #expect(
            !SuiDisplayableObjectRule.includes(objectType: "0xabc::capy::Capy", displayFields: ["description": "d"])
        )
    }
}

struct AptosNFTMappingTests {
    private func page(_ json: String) throws -> NFTPage {
        let response = try JSONDecoder().decode(AptosOwnedNFTsResponse.self, from: Data(json.utf8))
        return AptosClient.nftPage(response, offset: 0)
    }

    @Test func mapsV1AndV2RowsWithTransferabilityAndPosition() throws {
        let result = try page("""
            {"current_token_ownerships_v2": [
              {"amount": 0, "token_data_id": "0xa", "token_standard": "v2", "is_soulbound_v2": false,
               "non_transferrable_by_owner": false, "last_transaction_version": 100,
               "current_token_data": {"token_name": "A", "token_uri": "https://a", "collection_id": "0xc",
                                      "current_collection": {"collection_name": "Coll"}}},
              {"amount": 0, "token_data_id": "0xb", "token_standard": "v2", "is_soulbound_v2": true,
               "non_transferrable_by_owner": null, "last_transaction_version": "101", "current_token_data": null},
              {"amount": 0, "token_data_id": "0xd", "token_standard": "v2", "is_soulbound_v2": null,
               "non_transferrable_by_owner": true, "last_transaction_version": 102, "current_token_data": null},
              {"amount": "3", "token_data_id": "0xe", "token_standard": "v1", "is_soulbound_v2": null,
               "non_transferrable_by_owner": null, "last_transaction_version": 103, "current_token_data": null}
            ],
            "processor_status": [
              {"last_success_version": 500, "last_transaction_timestamp": "2026-11-21T10:00:00.123"}
            ]}
            """)

        #expect(result.cursor == nil)
        #expect(result.items.map(\.reference.isTransferable) == [true, false, false, false])
        #expect(result.items.map(\.reference.standard) == [.aptosTokenV2, .aptosTokenV2, .aptosTokenV2, .aptosTokenV1])
        #expect(result.items.map(\.quantity) == [1, 1, 1, 3])
        #expect(result.items[0].collectionName == "Coll")
        #expect(result.items[0].version == 100)

        guard case let .aptos(version, timestamp) = result.position else {
            Issue.record("missing position")
            return
        }

        #expect(version == 500)
        #expect(timestamp == Date(timeIntervalSince1970: 1_795_255_200))
    }

    @Test func objectTransferPayloadTargetsObjectModuleWithTokenType() throws {
        let object = try AptosAddress(string: "0x" + String(repeating: "ab", count: 32))
        let recipient = try AptosAddress(string: "0x" + String(repeating: "cd", count: 32))
        let payload = try AptosEntryFunction.tokenObjectTransfer(object: object, to: recipient)

        #expect(payload.identifier.hasSuffix("::object::transfer"))
        #expect(payload.arguments == [object.rawBytes, recipient.rawBytes])
        #expect(payload.typeArguments.count == 1)
    }
}

struct CardanoNFTTests {
    @Test func referenceUnitSwapsLabel222For100() {
        let policy = String(repeating: "a", count: 56)
        #expect(CardanoAssetLabel.referenceUnit(of: policy + "000de140" + "4d79") == policy + "000643b0" + "4d79")
        #expect(CardanoAssetLabel.referenceUnit(of: policy + "4d79") == nil)
    }

    @Test func decodesCIP68DatumWithChunkedImage() throws {
        // 121([{ "name": "My", "image": ["ipfs://", "abc"] }, 1, 0])
        var datum = Data([0xd8, 0x79, 0x9f, 0xa2])
        datum += Data([0x44]) + Data("name".utf8) + Data([0x42]) + Data("My".utf8)
        datum += Data([0x45]) + Data("image".utf8)
        datum += Data([0x82, 0x47]) + Data("ipfs://".utf8) + Data([0x43]) + Data("abc".utf8)
        datum += Data([0x01, 0x00, 0xff])

        let metadata = try #require(CardanoNFTMetadata(cip68Datum: datum))
        #expect(metadata.name == "My")
        #expect(metadata.image == "ipfs://abc")
    }

    @Test func rejectsNonConstructorDatum() {
        #expect(CardanoNFTMetadata(cip68Datum: Data([0x01])) == nil)
    }

    @Test func cip25ImageFallsBackToFilesAndJoinsChunks() {
        #expect(CardanoNFTMetadata(json: ["name": "N", "image": ["ipfs://", "x"]]).image == "ipfs://x")
        #expect(CardanoNFTMetadata(json: ["files": [["src": "ipfs://f"]]]).image == "ipfs://f")
    }
}
