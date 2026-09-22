import Foundation
import Testing
@testable import WalletKit

struct SolanaPKeySignerTests {
    private func makeSigner() throws -> SolanaPKeySigner {
        let seed = Mnemonic.generate().toSeed()
        let path = TestAccountFactory.slip10Path(coinType: 501)
        let privateKey = try seed.masterKey(curve: .ed25519).derive(path).privateKey()
        return try SolanaPKeySigner(network: .devnet, privateKey: privateKey, derivationPath: path)
    }

    @Test func addressMatchesTheRawEd25519PublicKey() throws {
        let signer = try makeSigner()
        let address = try signer.address()
        #expect(address.rawBytes == signer.account.publicKey.rawBytes)
    }

    @Test func initRejectsASecp256k1PrivateKey() throws {
        let seed = Mnemonic.generate().toSeed()
        let path = TestAccountFactory.bip44Path(coinType: 501)
        let privateKey = try seed.masterKey(curve: .secp256k1).derive(path).privateKey()
        #expect(throws: WalletKitError.self) {
            _ = try SolanaPKeySigner(privateKey: privateKey, derivationPath: path)
        }
    }

    @Test func signProducesA64ByteSignatureVerifiableByTheAccountsPublicKey() async throws {
        let signer = try makeSigner()
        let message = Data(repeating: 0xAB, count: 64) // stand-in for a compiled SolanaMessage
        let envelope = SolanaUnsignedTransaction(message: message)
        let payload = try JSONEncoder().encode(envelope)

        let signature = try await signer.sign(transaction: payload)
        #expect(signature.count == 64)
        #expect(signer.account.publicKey.verify(signature: signature, message: message))
    }

    @Test func signRejectsAPayloadThatIsNotAValidEnvelope() async throws {
        let signer = try makeSigner()
        await #expect(throws: (any Error).self) {
            _ = try await signer.sign(transaction: Data("not json".utf8))
        }
    }
}
