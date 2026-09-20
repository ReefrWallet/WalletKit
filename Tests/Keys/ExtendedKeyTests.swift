// Spec-driven test for Docs/Design Specification/Keys/ExtendedKey.swift.
// Will compile once the corresponding type is exported from Sources.

import Testing
@testable import WalletKit
import WalletKitRust

struct ExtendedKeyTests {
    @Test func deriveWalksTheFullRequestedPath() throws {
        let master = try Mnemonic.generate().toSeed().masterKey(curve: .secp256k1)
        let path = try DerivationPath(string: "m/44'/60'/0'/0/0")
        let derived = try master.derive(path)
        #expect(derived.depth == UInt8(path.segments.count))
    }

    @Test func deriveChildIncrementsDepthByOne() throws {
        let master = try Mnemonic.generate().toSeed().masterKey(curve: .secp256k1)
        let child = try master.deriveChild(index: 0, hardened: true)
        #expect(child.depth == master.depth + 1)
        #expect(child.isHardened == true)
    }

    @Test func publicOnlyKeyCannotProduceAPrivateKey() throws {
        let master = try Mnemonic.generate().toSeed().masterKey(curve: .secp256k1)
        let watchOnly = try ExtendedKey.fromSerialized(master.serializedPublic(), curve: .secp256k1)
        #expect(watchOnly.canDerivePrivate == false)
        #expect(throws: WalletKitError.self) {
            _ = try watchOnly.privateKey()
        }
    }

    @Test func serializedPrivateRoundTripsToTheSamePublicKey() throws {
        let master = try Mnemonic.generate().toSeed().masterKey(curve: .secp256k1)
        let restored = try ExtendedKey.fromSerialized(try master.serializedPrivate(), curve: .secp256k1)
        #expect(restored.serializedPublic() == master.serializedPublic())
    }

    @Test func invalidSerializedStringThrows() {
        #expect(throws: WalletKitError.self) {
            _ = try ExtendedKey.fromSerialized("not-a-valid-xprv", curve: .secp256k1)
        }
    }
}
