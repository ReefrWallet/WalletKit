import CryptoKit
import Foundation

/// A validated Tron Base58Check address.
public struct TronAddress: BlockchainAddress {
    private let bytes: Data

    public var rawBytes: Data { bytes }

    public var string: String {
        Base58.encode(bytes + Self.checksum(for: bytes))
    }

    public init(rawBytes: Data) throws {
        guard rawBytes.count == 21, rawBytes.first == 0x41 else {
            throw WalletKitError.invalidAddress(reason: "A Tron address must be 21 bytes beginning with 0x41.")
        }

        bytes = rawBytes
    }

    public init(string: String) throws {
        let decoded = try Base58.decode(string)
        guard decoded.count == 25 else {
            throw WalletKitError.invalidAddress(reason: "A Tron Base58Check address must decode to 25 bytes.")
        }

        let address = Data(decoded.prefix(21))
        guard Self.checksum(for: address) == Data(decoded.suffix(4)) else {
            throw WalletKitError.invalidAddress(reason: "Invalid Tron Base58Check checksum.")
        }

        try self.init(rawBytes: address)
    }

    public init(publicKey: PublicKey) throws {
        let ethereumAddress = try EthereumAddress(publicKey: publicKey)
        try self.init(rawBytes: Data([0x41]) + ethereumAddress.rawBytes)
    }

    public static func == (lhs: TronAddress, rhs: TronAddress) -> Bool {
        lhs.bytes == rhs.bytes
    }

    private static func checksum(for bytes: Data) -> Data {
        Data(SHA256.hash(data: Data(SHA256.hash(data: bytes))).prefix(4))
    }
}
