import CryptoKit
import Foundation

public final class TronPKeySigner: Signer {
    public typealias Address = TronAddress

    public let account: Account

    private let privateKey: PrivateKey

    public init(network: TronNetwork, privateKey: PrivateKey, derivationPath: DerivationPath) throws {
        guard privateKey.curve == .secp256k1 else {
            throw WalletKitError.unsupportedCurve(curve: privateKey.curve)
        }
        self.privateKey = privateKey
        account = Account(
            blockchain: .tron(network),
            derivationPath: derivationPath,
            curve: .secp256k1,
            source: .software,
            publicKey: privateKey.publicKey
        )
    }

    public func address() throws -> TronAddress {
        try TronAddress(publicKey: account.publicKey)
    }

    public func sign(transaction: Data) async throws -> Data {
        let request = try JSONDecoder().decode(TronUnsignedTransaction.self, from: transaction)
        let rawData = try Data(hexString: request.rawDataHex)
        let digest = Data(SHA256.hash(data: rawData))
        let signature = try remappingWalletKitError { try privateKey.raw.signPrehashedRecoverable(digest: digest) }
        // Tron transaction signatures use Ethereum's historical 27-based
        // recovery byte on the wire, not the raw 0/1 secp256k1 value.
        return signature.compact + Data([signature.recoveryId + 27])
    }
}

struct TronUnsignedTransaction: Codable {
    let rawDataHex: String

    enum CodingKeys: String, CodingKey {
        case rawDataHex = "raw_data_hex"
    }
}
