// Spec-driven test for Docs/Design Specification/Accounts/KeySource.swift.
// Will compile once the corresponding type is exported from Sources.

import Testing
@testable import WalletKit

struct KeySourceTests {
    @Test func softwareCasesAreEqual() {
        #expect(KeySource.software == KeySource.software)
    }

    @Test func hardwareCasesCompareByDeviceInfo() {
        let info = HardwareDeviceInfo(
            id: "abc123", vendor: .trezor, transport: .usb,
            model: "Trezor Safe 5", label: nil, firmwareVersion: "2.7.1",
            needsFirmwareUpdate: false
        )
        #expect(KeySource.hardware(info) == KeySource.hardware(info))
    }

    @Test func softwareAndHardwareAreNeverEqual() {
        let info = HardwareDeviceInfo(
            id: "abc123", vendor: .trezor, transport: .usb,
            model: "Trezor Safe 5", label: nil, firmwareVersion: nil,
            needsFirmwareUpdate: false
        )
        #expect(KeySource.software != KeySource.hardware(info))
    }
}
