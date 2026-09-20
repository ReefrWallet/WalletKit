// Spec-driven test for Docs/Design Specification/Keys/Seed.swift.
// Will compile once the corresponding type is exported from Sources.

import Foundation
import Testing
@testable import WalletKit

struct SeedTests {
    @Test func exportRawProduces64Bytes() {
        let seed = Mnemonic.generate().toSeed()
        #expect(seed.exportRaw().count == 64)
    }

    @Test func masterKeySupportsSecp256k1() throws {
        let seed = Mnemonic.generate().toSeed()
        let key = try seed.masterKey(curve: .secp256k1)
        #expect(key.curve == .secp256k1)
        #expect(key.depth == 0)
    }

    @Test func masterKeySupportsEd25519() throws {
        let seed = Mnemonic.generate().toSeed()
        let key = try seed.masterKey(curve: .ed25519)
        #expect(key.curve == .ed25519)
        #expect(key.depth == 0)
    }

    @Test func rawBytesRoundTripsThroughExportRaw() throws {
        let original = Mnemonic.generate().toSeed()
        let restored = try Seed(rawBytes: original.exportRaw())
        #expect(restored.exportRaw() == original.exportRaw())
    }

    @Test func rawBytesRejectsTheWrongByteCount() {
        #expect(throws: WalletKitError.self) {
            try Seed(rawBytes: Data(repeating: 0, count: 63))
        }
    }
}
