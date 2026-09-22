import Foundation
import Testing
@testable import WalletKit

struct TronPKeySignerTests {
    @Test func signsRawDataWithTronRecoveryByte() async throws {
        let privateKey = try PrivateKey(curve: .secp256k1, rawBytes: Data(repeating: 1, count: 32))
        let signer = try TronPKeySigner(
            network: .testnet,
            privateKey: privateKey,
            derivationPath: TestAccountFactory.bip44Path(coinType: 195)
        )
        let rawData = Data([0x0a, 0x02, 0xe9, 0x42])
        let transaction = try JSONSerialization.data(withJSONObject: ["raw_data_hex": rawData.hexEncoded])

        let signature = try await signer.sign(transaction: transaction)

        #expect(signature.count == 65)
        #expect((27...30).contains(signature.last ?? 0))
        #expect(signer.account.publicKey.verify(signature: Data(signature.dropLast()), message: rawData))
    }
}

private extension Data {
    var hexEncoded: String {
        map { String(format: "%02x", $0) }.joined()
    }
}
