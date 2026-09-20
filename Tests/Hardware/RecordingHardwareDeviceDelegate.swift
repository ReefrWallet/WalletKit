// Shared test double for Docs/Design Specification/Hardware/HardwareDeviceDelegate.swift.
// Used by HardwareDeviceDelegateTests, HardwareDeviceManagerTests, and
// HardwareDeviceTests. Not a @Test file itself.

@testable import WalletKit

final class RecordingHardwareDeviceDelegate: HardwareDeviceDelegate {
    private(set) var inputRequests: [HardwareInputRequest] = []
    private(set) var confirmationRequests: [HardwareButtonRequest] = []
    private(set) var didDisconnect = false

    /// Response returned from `needsInput`; set to `nil` to simulate the
    /// user cancelling the in-flight operation.
    var inputResponse: String?

    func hardwareDevice(_ device: HardwareDevice, needsInput request: HardwareInputRequest) async -> String? {
        inputRequests.append(request)
        return inputResponse
    }

    func hardwareDevice(_ device: HardwareDevice, waitingForConfirmation request: HardwareButtonRequest) async {
        confirmationRequests.append(request)
    }

    func hardwareDeviceDidDisconnect(_ device: HardwareDevice) {
        didDisconnect = true
    }
}
