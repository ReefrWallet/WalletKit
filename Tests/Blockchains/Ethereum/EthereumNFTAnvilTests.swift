//
//  EthereumNFTAnvilTests.swift
//  WalletKit
//
//  Copyright © 2026 Reefr Wallet. All rights reserved.
//

import BigInt
import Foundation
import Testing
import WalletKit
import WalletKitTesting

@Suite(.timeLimit(.minutes(1)), .localNode)
struct EthereumNFTAnvilTests {
    private static let deployerKey = "ac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80"
    private static let ownerKey = "59c6995e998f97a5a0044966f0945389dc9e86dae88c7a8412f4603b6b78690d"

    private func signer(_ hex: String, chainId: UInt64) throws -> EthereumPKeySigner {
        let bytes = Data(stride(from: 0, to: hex.count, by: 2).map { offset in
            let start = hex.index(hex.startIndex, offsetBy: offset)
            return UInt8(hex[start..<hex.index(start, offsetBy: 2)], radix: 16) ?? 0
        })

        return try EthereumPKeySigner(
            chainId: chainId,
            privateKey: PrivateKey(curve: .secp256k1, rawBytes: bytes),
            derivationPath: TestAccountFactory.bip44Path(coinType: 60)
        )
    }

    private func uint(_ data: Data) -> BigUInt {
        EthereumABI.decodeUInt256(data.prefix(32))
    }

    // swiftlint:disable:next function_body_length
    @Test func sendsERC721AndERC1155AndReadsMetadataURIs() async throws {
        let node = try await EthereumNode.start()
        defer { node.stop() }

        let deployer = try signer(Self.deployerKey, chainId: node.chainId)
        let owner = try signer(Self.ownerKey, chainId: node.chainId)
        let ownerAddress = try owner.address()
        let recipient = try EthereumAddress(rawBytes: Data(repeating: 0x42, count: 20))
        let client = EthereumRPCClient(endpoint: node.endpoint, chainId: node.chainId)
        let builder = EthereumTransactionBuilder(client: client)

        let erc721 = try await node.deployMockERC721(signer: deployer)
        let erc1155 = try await node.deployMockERC1155(signer: deployer)
        try await node.mintERC721(signer: deployer, contract: erc721, recipient: ownerAddress, id: 7)
        try await node.mintERC1155(signer: deployer, contract: erc1155, recipient: ownerAddress, id: 3, amount: 5)

        let unique = NFTReference(collection: erc721.string, isTransferable: true, standard: .erc721, tokenId: "7")
        let multiple = NFTReference(collection: erc1155.string, isTransferable: true, standard: .erc1155, tokenId: "3")

        let uris = try await client.nftMetadataURIs([unique, multiple])
        #expect(uris[0]?.hasPrefix("data:application/json") == true)
        #expect(uris[1] == "https://example.invalid/" + String(repeating: "0", count: 63) + "3.json")

        for (nft, quantity) in [(unique, BigUInt(1)), (multiple, BigUInt(2))] {
            let transaction = try await builder.buildNFTTransfer(
                sender: ownerAddress.string,
                recipient: recipient.string,
                nft: nft,
                quantity: quantity,
                options: []
            )
            let signature = try await owner.sign(transaction: transaction)
            let hash = try await client.broadcast(transaction: transaction, signature: signature)
            _ = try await node.waitForReceipt(hash)
        }

        let ownerOf = try await client.call(
            to: erc721,
            data: EthereumABI.encodeCall(selector: EthereumABI.selector("ownerOf(uint256)"), parameters: [.uint256(7)])
        )
        #expect(try EthereumABI.decodeAddress(ownerOf.prefix(32)) == recipient)

        let balance = try await client.call(
            to: erc1155,
            data: EthereumABI.encodeCall(
                selector: EthereumABI.selector("balanceOf(uint256,address)"),
                parameters: [.uint256(3), .address(ownerAddress)]
            )
        )
        #expect(uint(balance) == 3)
    }

    @Test func nonTransferableNFTIsRejected() async throws {
        let client = EthereumRPCClient(endpoint: URL(string: "http://127.0.0.1:1")!, chainId: 1)
        let nft = NFTReference(collection: "0x" + String(repeating: "11", count: 20), isTransferable: false, standard: .erc721, tokenId: "1")

        await #expect(throws: BlockchainTransactionBuilderError.self) {
            try await EthereumTransactionBuilder(client: client).buildNFTTransfer(
                sender: "0x" + String(repeating: "22", count: 20),
                recipient: "0x" + String(repeating: "33", count: 20),
                nft: nft,
                quantity: 1,
                options: []
            )
        }
    }
}
