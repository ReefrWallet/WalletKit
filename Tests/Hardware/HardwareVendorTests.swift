// Spec-driven test for Docs/Design Specification/Hardware/HardwareVendor.swift.
// Will compile once the corresponding type is exported from Sources.

import Testing
@testable import WalletKit

struct HardwareVendorTests {
    @Test func allCasesIncludesTrezor() {
        #expect(HardwareVendor.allCases.contains(.trezor))
    }
}
