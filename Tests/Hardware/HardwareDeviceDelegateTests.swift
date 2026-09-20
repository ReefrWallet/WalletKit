// Spec-driven test for Docs/Design Specification/Hardware/HardwareDeviceDelegate.swift.
// Will compile once the corresponding type is exported from Sources.
//
// Every delegate method takes a `HardwareDevice`, which only
// `HardwareDeviceManager.connect(_:delegate:)` can produce, so exercising
// the actual PIN/confirmation callback flow belongs in
// HardwareDeviceManagerTests/HardwareDeviceTests against a connected (or
// mocked) device. This file verifies the mock's own contract in isolation.

import Testing
@testable import WalletKit

struct HardwareDeviceDelegateTests {
    @Test func recordingDelegateStartsWithNoRecordedCalls() {
        let delegate = RecordingHardwareDeviceDelegate()
        #expect(delegate.inputRequests.isEmpty)
        #expect(delegate.confirmationRequests.isEmpty)
        #expect(delegate.didDisconnect == false)
    }

    @Test func recordingDelegateConformsToHardwareDeviceDelegate() {
        let delegate: HardwareDeviceDelegate = RecordingHardwareDeviceDelegate()
        #expect(delegate is RecordingHardwareDeviceDelegate)
    }
}
