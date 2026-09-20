// Spec-driven test for Docs/Design Specification/Hardware/HardwareInputRequest.swift.
// Will compile once the corresponding type is exported from Sources.

import Testing
@testable import WalletKit

struct HardwareInputRequestTests {
    @Test func pinCasesWithDifferentAttemptsAreNotEqual() {
        #expect(HardwareInputRequest.pin(attempt: 1) != .pin(attempt: 2))
    }

    @Test func passphraseCasesAreEqual() {
        #expect(HardwareInputRequest.passphrase == HardwareInputRequest.passphrase)
    }
}
