// Spec-driven test for Docs/Design Specification/Core/DerivationScheme.swift.
// Will compile once the corresponding type is exported from Sources.

import Testing
@testable import WalletKit
import WalletKitRust

struct DerivationSchemeTests {
    @Test func bip32AndSlip0010AreDistinct() {
        #expect(DerivationScheme.bip32 != DerivationScheme.slip0010)
    }
}
