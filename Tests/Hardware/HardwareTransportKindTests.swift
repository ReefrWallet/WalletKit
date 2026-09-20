// Spec-driven test for Docs/Design Specification/Hardware/HardwareTransportKind.swift.
// Will compile once the corresponding type is exported from Sources.

import Testing
@testable import WalletKit

struct HardwareTransportKindTests {
    @Test func allCasesCoversUsbBluetoothAndQrAirGap() {
        #expect(HardwareTransportKind.allCases == [.usb, .bluetooth, .qrAirGap])
    }
}
