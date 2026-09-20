// Spec-driven test for Docs/Design Specification/Keys/PublicKey.swift.
// Will compile once the corresponding type is exported from Sources.

import Foundation
import Testing
@testable import WalletKit

struct PublicKeyTests {
    @Test func secp256k1RawBytesAreCompressed33Bytes() throws {
        let key = try Mnemonic.generate().toSeed().masterKey(curve: .secp256k1).publicKey
        #expect(key.rawBytes.count == 33)
    }

    @Test func ed25519RawBytesAre32Bytes() throws {
        let key = try Mnemonic.generate().toSeed().masterKey(curve: .ed25519).publicKey
        #expect(key.rawBytes.count == 32)
    }

    @Test func verifyAcceptsASignatureFromTheMatchingPrivateKey() throws {
        let extendedKey = try Mnemonic.generate().toSeed().masterKey(curve: .secp256k1)
        let message = Data("hello walletkit".utf8)
        let signature = try extendedKey.privateKey().sign(message: message)
        #expect(extendedKey.publicKey.verify(signature: signature, message: message))
    }

    @Test func verifyRejectsATamperedMessage() throws {
        let extendedKey = try Mnemonic.generate().toSeed().masterKey(curve: .secp256k1)
        let signature = try extendedKey.privateKey().sign(message: Data("hello".utf8))
        #expect(extendedKey.publicKey.verify(signature: signature, message: Data("goodbye".utf8)) == false)
    }
}
