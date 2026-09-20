// Spec-driven test for Docs/Design Specification/Hardware/HardwareDeviceInfo.swift.
// Will compile once the corresponding type is exported from Sources.

import Testing
@testable import WalletKit

struct HardwareDeviceInfoTests {
    @Test func initPreservesAllFields() {
        let info = HardwareDeviceInfo(
            id: "abc123", vendor: .trezor, transport: .bluetooth,
            model: "Trezor Safe 7", label: "My Trezor",
            firmwareVersion: "2.8.0", needsFirmwareUpdate: false
        )
        #expect(info.id == "abc123")
        #expect(info.vendor == .trezor)
        #expect(info.transport == .bluetooth)
        #expect(info.model == "Trezor Safe 7")
        #expect(info.label == "My Trezor")
        #expect(info.firmwareVersion == "2.8.0")
        #expect(info.needsFirmwareUpdate == false)
    }

    @Test func labelAndFirmwareVersionAreOptional() {
        let info = HardwareDeviceInfo(
            id: "abc123", vendor: .trezor, transport: .usb,
            model: "Trezor Model T", label: nil, firmwareVersion: nil,
            needsFirmwareUpdate: true
        )
        #expect(info.label == nil)
        #expect(info.firmwareVersion == nil)
    }
}
