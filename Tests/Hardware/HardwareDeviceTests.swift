// Spec-driven test for Docs/Design Specification/Hardware/HardwareDevice.swift.
// Will compile once the corresponding type is exported from Sources.
//
// Requires a connected (or mocked) Trezor; tests scan first and return early
// when none is available rather than failing.

import Testing
@testable import WalletKit

// No real transport (USB/Bluetooth) integration yet, so nothing is
// ever discovered — `devices` is always empty.

struct HardwareDeviceTests {
    @Test func sourceReflectsTheDevicesInfo() async throws {
        try await withExclusiveHardwareAccess {
            let manager = HardwareDeviceManager()
            let devices = try await manager.scan()
            guard let info = devices.first else {
                return
            }

            let device = try await manager.connect(info, delegate: RecordingHardwareDeviceDelegate())
            #expect(device.source == .hardware(device.info))
        }
    }

    @Test func accountAndPublicKeyAgreeOnTheSameProviderAndPath() async throws {
        try await withExclusiveHardwareAccess {
            let manager = HardwareDeviceManager()
            let devices = try await manager.scan()
            guard let info = devices.first else {
                return
            }

            let device = try await manager.connect(info, delegate: RecordingHardwareDeviceDelegate())
            let account = try await device.account(.evm(.ethereum(.mainnet)))
            let key = try await device.publicKey(path: account.derivationPath, curve: .secp256k1)
            #expect(account.publicKey.rawBytes == key.rawBytes)
        }
    }

    @Test func disconnectCompletesForAConnectedDevice() async throws {
        try await withExclusiveHardwareAccess {
            let manager = HardwareDeviceManager()
            let devices = try await manager.scan()
            guard let info = devices.first else {
                return
            }

            let device = try await manager.connect(info, delegate: RecordingHardwareDeviceDelegate())
            await device.disconnect()
        }
    }
}
