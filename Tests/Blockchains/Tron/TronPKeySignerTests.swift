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

    /// Vectors from TronWeb 6.5.1 `trx.signMessageV2` with the same key.
    @Test(arguments: [
        (
            Data("hello".utf8),
            "2bc71605e8a1d96de63cba90f01591e08ee1d2c3592e8a5f12cd4d66d731c719"
                + "3ce8ee7f17edf7b8d3568f182ae32abb3bc9e173fa48e0a86a5bf8aedbd9659b1b"
        ),
        (
            Data([0xde, 0xad, 0xbe, 0xef]),
            "d189596c24a8f5992a3c630404555725ac8c2384ec8ddaa8c9600c2ce8e7ddc8"
                + "49a51680e08a2c63147152ef0be260cdd2953ae2b35635c1a3d7046ef636b3b01c"
        )
    ])
    func signsMessagesLikeTronWebV2(message: Data, expectedHex: String) async throws {
        let privateKey = try PrivateKey(curve: .secp256k1, rawBytes: Data(repeating: 1, count: 32))
        let signer = try TronPKeySigner(
            network: .mainnet,
            privateKey: privateKey,
            derivationPath: TestAccountFactory.bip44Path(coinType: 195)
        )

        #expect(try signer.address().string == "TCNkawTmcQgYSU8nP8cHswT1QPjharxJr7")

        let signature = try await signer.sign(message: .tronMessage(message))
        #expect(signature.hexEncoded == expectedHex)
    }

    @Test func rejectsOtherChainsMessages() async throws {
        let privateKey = try PrivateKey(curve: .secp256k1, rawBytes: Data(repeating: 1, count: 32))
        let signer = try TronPKeySigner(
            network: .mainnet,
            privateKey: privateKey,
            derivationPath: TestAccountFactory.bip44Path(coinType: 195)
        )

        await #expect(throws: WalletKitError.self) {
            try await signer.sign(message: .ethereumPersonal(Data("hello".utf8)))
        }
    }
}

private extension Data {
    var hexEncoded: String {
        map { String(format: "%02x", $0) }.joined()
    }
}
