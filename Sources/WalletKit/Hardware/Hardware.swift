//
//  Hardware.swift
//  WalletKit
//
//  Created by Andrey Yurkevich on 16/08/2026.
//

import WalletKitRust

/// A supported hardware wallet manufacturer.
public enum HardwareVendor: String, Codable, CaseIterable, Sendable {
    case trezor

    init(_ raw: HardwareVendorFfi) {
        switch raw {
        case .trezor:
            self = .trezor
        }
    }

    var raw: HardwareVendorFfi {
        switch self {
        case .trezor: .trezor
        }
    }
}

/// A physical/logical transport a hardware device can be reached over.
public enum HardwareTransportKind: String, Codable, CaseIterable, Sendable {
    case usb
    case bluetooth
    case qrAirGap

    public init?(rawValue: HardwareTransportKindFfi) {
        switch rawValue {
        case .usb:
            self = .usb
        case .bluetooth:
            self = .bluetooth
        case .qrAirGap:
            self = .qrAirGap
        }
    }

    public var rawValue: HardwareTransportKindFfi {
        switch self {
        case .usb: .usb
        case .bluetooth: .bluetooth
        case .qrAirGap: .qrAirGap
        }
    }
}

// These are plain data types with no cryptography or FFI-object handle
// involved, so — unlike ``HardwareVendor``/``HardwareTransportKind`` —
// they're UniFFI-generated and re-exported as-is rather than hand-wrapped;
// see `Docs/Overview.md`'s "FFI / bindings strategy".

/// A piece of input a hardware device is asking the user to provide,
/// relayed to the app via ``HardwareDeviceDelegate``.
@_documentation(visibility: internal) @_exported import enum WalletKitRust.HardwareInputRequest

/// A physical confirmation the device is waiting for the user to perform
/// on its own screen/buttons, relayed to the app via
/// ``HardwareDeviceDelegate`` so the UI can show "check your device"-style
/// messaging.
@_documentation(visibility: internal) @_exported import enum WalletKitRust.HardwareButtonRequest
