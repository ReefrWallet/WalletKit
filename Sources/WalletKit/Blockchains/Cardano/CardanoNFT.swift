//
//  CardanoNFT.swift
//  WalletKit
//
//  Copyright © 2026 Reefr Wallet. All rights reserved.
//

import BigInt
import Foundation

// MARK: - Asset labels

/// CIP-67 asset name labels.
enum CardanoAssetLabel {
    static let fungible = "0014df10" // 333
    static let reference = "000643b0" // 100
    static let user = "000de140" // 222

    /// The label-100 reference unit of a CIP-68 label-222 `unit`.
    static func referenceUnit(of unit: String) -> String? {
        let name = unit.dropFirst(56)
        guard name.hasPrefix(user) else {
            return nil
        }

        return String(unit.prefix(56)) + reference + name.dropFirst(user.count)
    }
}

// MARK: - Metadata

/// The NFT fields of CIP-25 `onchain_metadata` or a CIP-68 datum's metadata map.
public struct CardanoNFTMetadata: Equatable, Sendable {
    public let image: String?
    public let name: String?

    public init(image: String?, name: String?) {
        self.image = image
        self.name = name
    }

    /// Reads `name`, and `image` (a string, or chunks joined) falling back to
    /// the first `files[].src`.
    init(json: [String: Any]) {
        func text(_ value: Any?) -> String? {
            if let string = value as? String {
                return string
            }

            if let chunks = value as? [String] {
                return chunks.joined()
            }

            return nil
        }

        let files = json["files"] as? [[String: Any]]
        self.init(image: text(json["image"]) ?? text(files?.first?["src"]), name: text(json["name"]))
    }

    /// Decodes a CIP-68 reference datum: `Constr 0 [metadata, version, extra]`
    /// (CBOR tag 121), where `metadata` maps UTF-8 byte keys to byte, text or
    /// chunk-list values.
    public init?(cip68Datum: Data) {
        guard case let .tag(121, .array(fields)) = try? CardanoCBOR.decode(cip68Datum),
              case let .map(entries) = fields.first
        else {
            return nil
        }

        var values: [String: String] = [:]

        for (key, value) in entries {
            guard let key = key.utf8String, let value = value.utf8String else {
                continue
            }

            values[key] = value
        }

        self.init(image: values["image"], name: values["name"])
    }
}

/// A minimal CBOR decoder for Plutus data.
enum CardanoCBOR {
    indirect enum Value: Equatable {
        case array([Value])
        case bytes(Data)
        case map([(Value, Value)])
        case negative(UInt64)
        case simple(UInt8)
        case tag(UInt64, Value)
        case text(String)
        case unsigned(UInt64)

        static func == (lhs: Value, rhs: Value) -> Bool {
            switch (lhs, rhs) {
            case let (.array(lhs), .array(rhs)):
                lhs == rhs
            case let (.bytes(lhs), .bytes(rhs)):
                lhs == rhs
            case let (.map(lhs), .map(rhs)):
                lhs.count == rhs.count && zip(lhs, rhs).allSatisfy { $0.0 == $1.0 && $0.1 == $1.1 }
            case let (.negative(lhs), .negative(rhs)), let (.unsigned(lhs), .unsigned(rhs)):
                lhs == rhs
            case let (.simple(lhs), .simple(rhs)):
                lhs == rhs
            case let (.tag(lhsTag, lhs), .tag(rhsTag, rhs)):
                lhsTag == rhsTag && lhs == rhs
            case let (.text(lhs), .text(rhs)):
                lhs == rhs
            default:
                false
            }
        }

        /// UTF-8 text of a byte string, text string, or list of either.
        var utf8String: String? {
            switch self {
            case let .array(chunks):
                let parts = chunks.compactMap(\.utf8String)
                return parts.count == chunks.count ? parts.joined() : nil
            case let .bytes(data):
                return String(data: data, encoding: .utf8)
            case let .text(string):
                return string
            default:
                return nil
            }
        }
    }

    enum DecodingError: Error {
        case invalid
    }

    static func decode(_ data: Data) throws -> Value {
        var reader = Reader(bytes: [UInt8](data))
        return try reader.value()
    }

    private struct Reader {
        let bytes: [UInt8]
        var offset = 0

        mutating func value() throws -> Value {
            let initial = try byte()
            let major = initial >> 5
            let info = initial & 0x1f

            switch major {
            case 0:
                return .unsigned(try argument(info))
            case 1:
                return .negative(try argument(info))
            case 2:
                return .bytes(try string(info, major: 2))
            case 3:
                guard let text = String(data: try string(info, major: 3), encoding: .utf8) else {
                    throw DecodingError.invalid
                }

                return .text(text)
            case 4:
                return .array(try items(info) { try $0.value() })
            case 5:
                return .map(try items(info) { reader in (try reader.value(), try reader.value()) })
            case 6:
                return .tag(try argument(info), try value())
            default:
                return .simple(info)
            }
        }

        private mutating func argument(_ info: UInt8) throws -> UInt64 {
            switch info {
            case 0..<24:
                return UInt64(info)
            case 24...27:
                let count = 1 << Int(info - 24)
                return try (0..<count).reduce(UInt64(0)) { result, _ in result << 8 | UInt64(try byte()) }
            default:
                throw DecodingError.invalid
            }
        }

        private mutating func byte() throws -> UInt8 {
            guard offset < bytes.count else {
                throw DecodingError.invalid
            }

            defer { offset += 1 }
            return bytes[offset]
        }

        private mutating func items<Item>(_ info: UInt8, _ next: (inout Reader) throws -> Item) throws -> [Item] {
            var result: [Item] = []

            if info == 31 {
                while try peek() != 0xff {
                    result.append(try next(&self))
                }

                offset += 1
                return result
            }

            for _ in 0..<(try argument(info)) {
                result.append(try next(&self))
            }

            return result
        }

        private func peek() throws -> UInt8 {
            guard offset < bytes.count else {
                throw DecodingError.invalid
            }

            return bytes[offset]
        }

        private mutating func string(_ info: UInt8, major: UInt8) throws -> Data {
            if info == 31 {
                var result = Data()

                while try peek() != 0xff {
                    let chunk = try byte()
                    guard chunk >> 5 == major else {
                        throw DecodingError.invalid
                    }

                    result += try string(chunk & 0x1f, major: major)
                }

                offset += 1
                return result
            }

            let length = Int(try argument(info))
            guard length >= 0, offset + length <= bytes.count else {
                throw DecodingError.invalid
            }

            defer { offset += length }
            return Data(bytes[offset..<offset + length])
        }
    }
}

// MARK: - Listing

extension CardanoClient: NFTListing {
    private struct AssetInfo: Decodable {
        let onchainMetadata: AnyJSON?
        let onchainMetadataStandard: String?
        let policyId: String
        let quantity: String

        enum CodingKeys: String, CodingKey {
            case onchainMetadata = "onchain_metadata"
            case onchainMetadataStandard = "onchain_metadata_standard"
            case policyId = "policy_id"
            case quantity
        }
    }

    private struct AssetAddress: Decodable {
        let address: String
    }

    /// Lists the account's CIP-25 NFTs (total supply 1, with on-chain
    /// metadata) and CIP-68 user tokens (label 222), in one page. CIP-68
    /// metadata comes from Blockfrost when it resolves it, otherwise from the
    /// label-100 reference token's inline datum; failing both, the asset is
    /// listed without metadata. The position is the set of UTxOs read.
    public func ownedNFTs(_ owner: String, cursor: String?, minContextSlot: UInt64?) async throws -> NFTPage {
        let descriptor = try makeAddress(owner)
        let entries = try await accountUTxOs(descriptor)
        var quantities: [String: BigUInt] = [:]

        for entry in entries {
            for amount in entry.amount where amount.unit != "lovelace" {
                quantities[amount.unit, default: 0] += BigUInt(amount.quantity) ?? 0
            }
        }

        var items: [OwnedNFT] = []

        for (unit, quantity) in quantities.sorted(by: { $0.key < $1.key }) {
            if let item = try await nft(unit: unit, quantity: quantity) {
                items.append(item)
            }
        }

        let outpoints = Set(entries.map { "\($0.txHash)#\($0.outputIndex)" })
        return NFTPage(cursor: nil, items: items, position: .cardano(outpoints: outpoints))
    }

    private func nft(unit: String, quantity: BigUInt) async throws -> OwnedNFT? {
        let name = unit.dropFirst(56)
        guard unit.count >= 56, !name.hasPrefix(CardanoAssetLabel.reference), !name.hasPrefix(CardanoAssetLabel.fungible) else {
            return nil
        }

        let isCIP68 = name.hasPrefix(CardanoAssetLabel.user)
        let asset: AssetInfo = try await get("assets/\(unit)")
        var metadata = (asset.onchainMetadata?.value as? [String: Any]).map(CardanoNFTMetadata.init(json:))

        if isCIP68 {
            if metadata?.name == nil, metadata?.image == nil {
                metadata = try? await referenceMetadata(of: unit)
            }
        } else if asset.quantity != "1" || metadata == nil {
            return nil
        }

        let fallbackName = (try? Data(hexString: String(name.dropFirst(isCIP68 ? CardanoAssetLabel.user.count : 0))))
            .flatMap { String(data: $0, encoding: .utf8) }

        return OwnedNFT(
            imageURI: metadata?.image,
            name: metadata?.name ?? fallbackName,
            quantity: quantity,
            reference: NFTReference(
                collection: asset.policyId,
                isTransferable: true,
                standard: isCIP68 ? .cardanoCIP68 : .cardanoCIP25,
                tokenId: unit
            )
        )
    }

    /// Reads a CIP-68 user token's metadata from its reference token's datum.
    func referenceMetadata(of unit: String) async throws -> CardanoNFTMetadata? {
        guard let reference = CardanoAssetLabel.referenceUnit(of: unit) else {
            return nil
        }

        let addresses: [AssetAddress] = try await get("assets/\(reference)/addresses")
        guard let address = addresses.first?.address else {
            return nil
        }

        let utxos: [UTxO] = try await get("addresses/\(address)/utxos/\(reference)")
        guard let datum = utxos.lazy.compactMap(\.inlineDatum).first, let bytes = try? Data(hexString: datum) else {
            return nil
        }

        return CardanoNFTMetadata(cip68Datum: bytes)
    }
}

/// Any JSON value, decoded into Foundation types.
struct AnyJSON: Decodable {
    let value: Any

    init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()

        if container.decodeNil() {
            value = NSNull()
        } else if let bool = try? container.decode(Bool.self) {
            value = bool
        } else if let number = try? container.decode(Double.self) {
            value = number
        } else if let string = try? container.decode(String.self) {
            value = string
        } else if let array = try? container.decode([AnyJSON].self) {
            value = array.map(\.value)
        } else {
            value = try container.decode([String: AnyJSON].self).mapValues(\.value)
        }
    }
}

// MARK: - Transfer

extension CardanoTransactionBuilder: NFTTransactionBuilding {
    /// Transfers `quantity` of the asset unit as a native-asset transfer;
    /// pass ``BlockchainTransactionBuilderOptions/cardanoRecipientLovelace(_:)``
    /// for the ADA sent with it.
    public func buildNFTTransfer(
        sender: String,
        recipient: String,
        nft: NFTReference,
        quantity: BigUInt,
        options: [BlockchainTransactionBuilderOptions]
    ) async throws -> Data {
        try requireTransferable(nft, standards: [.cardanoCIP25, .cardanoCIP68])

        return try await buildTransfer(
            sender: makeAddress(sender),
            recipient: makeAddress(recipient),
            amount: quantity,
            token: nft.tokenId,
            options: options
        )
    }
}
