// Spec-driven test for Docs/Design Specification/Errors/WalletKitError.swift.
// Will compile once the corresponding type is exported from Sources.

import Testing
@testable import WalletKit

struct WalletKitErrorTests {
    @Test func associatedValuesAreComparedForEquality() {
        #expect(WalletKitError.invalidMnemonic(reason: "bad checksum") == .invalidMnemonic(reason: "bad checksum"))
        #expect(WalletKitError.invalidMnemonic(reason: "a") != .invalidMnemonic(reason: "b"))
    }

    @Test func distinctCasesAreNotEqual() {
        #expect(WalletKitError.invalidEntropy != WalletKitError.invalidPassphrase)
    }

    @Test func hardwareErrorCasesConstructWithTheirPayloads() {
        let cases: [WalletKitError] = [
            .deviceNotFound,
            .deviceDisconnected,
            .deviceLocked,
            .deviceBusy,
            .userRejectedOnDevice,
            .transportUnavailable(reason: "usb unavailable on iOS"),
            .unsupportedDevice(reason: "unknown model"),
            .firmwareOutdated(minimumVersion: "2.6.0")
        ]
        #expect(cases.count == 8)
    }
}
