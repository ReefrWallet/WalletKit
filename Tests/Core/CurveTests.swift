// Spec-driven test for Docs/Design Specification/Core/Curve.swift.
// Will compile once the corresponding type is exported from Sources.

import Testing
@testable import WalletKit
import WalletKitRust

struct CurveTests {
    @Test func allCasesCoversSecp256k1AndEd25519() {
        #expect(Curve.allCases == [.secp256k1, .ed25519])
    }

    @Test func distinctCasesAreNotEqual() {
        #expect(Curve.secp256k1 != Curve.ed25519)
    }
}
