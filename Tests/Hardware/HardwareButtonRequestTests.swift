// Spec-driven test for Docs/Design Specification/Hardware/HardwareButtonRequest.swift.
// Will compile once the corresponding type is exported from Sources.

import Testing
@testable import WalletKit

struct HardwareButtonRequestTests {
    @Test func otherCasesCompareByDescription() {
        #expect(HardwareButtonRequest.other(description: "confirm export") == .other(description: "confirm export"))
        #expect(HardwareButtonRequest.other(description: "a") != .other(description: "b"))
    }

    @Test func distinctFixedCasesAreNotEqual() {
        #expect(HardwareButtonRequest.confirmAddress != .confirmTransaction)
    }
}
