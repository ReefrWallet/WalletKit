// Spec-driven test for Docs/Design Specification/Keys/PrivateKey.swift.
// Will compile once the corresponding type is exported from Sources.

import Foundation
import Testing
@testable import WalletKit

struct PrivateKeyTests {
    @Test func publicKeyMatchesTheDerivingExtendedKeysPublicKey() throws {
        let extendedKey = try Mnemonic.generate().toSeed().masterKey(curve: .secp256k1)
        let privateKey = try extendedKey.privateKey()
        #expect(privateKey.publicKey.rawBytes == extendedKey.publicKey.rawBytes)
    }

    @Test func signProducesASignatureVerifiableByItsOwnPublicKey() throws {
        let extendedKey = try Mnemonic.generate().toSeed().masterKey(curve: .secp256k1)
        let privateKey = try extendedKey.privateKey()
        let message = Data("sign me".utf8)
        let signature = try privateKey.sign(message: message)
        #expect(privateKey.publicKey.verify(signature: signature, message: message))
    }

    @Test func curveMatchesTheDerivingExtendedKeysCurve() throws {
        let extendedKey = try Mnemonic.generate().toSeed().masterKey(curve: .ed25519)
        #expect(try extendedKey.privateKey().curve == .ed25519)
    }
}
