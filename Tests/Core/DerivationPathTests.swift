// Spec-driven test for Docs/Design Specification/Core/DerivationPath.swift.
// Will compile once the corresponding type is exported from Sources.

import Testing
@testable import WalletKit
import WalletKitRust

struct DerivationPathTests {
    @Test func parsesStandardBip44String() throws {
        let path = try DerivationPath(string: "m/44'/60'/0'/0/0")
        #expect(path.segments.map(\.index) == [44, 60, 0, 0, 0])
        #expect(path.segments.map(\.hardened) == [true, true, true, false, false])
    }

    @Test func stringRoundTripsThroughParsing() throws {
        let original = "m/44'/60'/0'/0/0"
        let path = try DerivationPath(string: original)
        #expect(path.string == original)
    }

    @Test func invalidStringThrowsInvalidDerivationPath() {
        #expect(throws: WalletKitError.self) {
            _ = try DerivationPath(string: "not-a-path")
        }
    }
}
