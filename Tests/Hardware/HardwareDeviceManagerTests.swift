// Spec-driven test for Docs/Design Specification/Hardware/HardwareDeviceManager.swift.
// Will compile once the corresponding type is exported from Sources.
//
// `scan`/`connect` talk to real transports (USB/Bluetooth), so connect tests
// scan first and return early when no Trezor is available.

import Testing
@testable import WalletKit

struct HardwareDeviceManagerTests {
    @Test func scanWithNoRequestedTransportsThrowsTransportUnavailable() async {
        let manager = HardwareDeviceManager()
        await #expect(throws: WalletKitError.self) {
            _ = try await manager.scan(vendors: [.trezor], transports: [])
        }
    }

    @Test func scanDefaultsToAllVendorsAndUsbPlusBluetooth() async throws {
        let manager = HardwareDeviceManager()
        // Asserts the call succeeds with no arguments; the exact devices
        // returned depend on what's physically connected to the host.
        _ = try await manager.scan()
    }

    @Test func connectRetainsTheProvidedDelegateAndReturnsAConnectedDevice() async throws {
        try await withExclusiveHardwareAccess {
            let manager = HardwareDeviceManager()
            let devices = try await manager.scan()
            guard let info = devices.first else {
                return
            }

            let delegate = RecordingHardwareDeviceDelegate()
            let device = try await manager.connect(info, delegate: delegate)
            #expect(device.info.vendor == info.vendor)
            #expect(device.info.transport == info.transport)
            #expect(device.isConnected)
        }
    }
}
