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

/// A piece of input a hardware device is asking the user to provide,
/// relayed to the app via ``HardwareDeviceDelegate``.
public enum HardwareInputRequest: Codable, Equatable, Hashable, Sendable {
    case passphrase
    case pin(attempt: UInt32)

    init(raw: HardwareInputRequestFfi) {
        switch raw {
        case .passphrase:
            self = .passphrase
        case let .pin(attempt):
            self = .pin(attempt: attempt)
        }
    }

    var raw: HardwareInputRequestFfi {
        switch self {
        case .passphrase:
            .passphrase
        case let .pin(attempt):
            .pin(attempt: attempt)
        }
    }
}

/// A physical confirmation the device is waiting for the user to perform
/// on its own screen/buttons, relayed to the app via
/// ``HardwareDeviceDelegate`` so the UI can show "check your device"-style
/// messaging.
public enum HardwareButtonRequest: Codable, Equatable, Hashable, Sendable {
    case confirmAddress
    case confirmPublicKey
    case confirmTransaction
    case other(description: String)

    init(raw: HardwareButtonRequestFfi) {
        switch raw {
        case .confirmAddress:
            self = .confirmAddress
        case .confirmPublicKey:
            self = .confirmPublicKey
        case .confirmTransaction:
            self = .confirmTransaction
        case let .other(description):
            self = .other(description: description)
        }
    }

    var raw: HardwareButtonRequestFfi {
        switch self {
        case .confirmAddress:
            .confirmAddress
        case .confirmPublicKey:
            .confirmPublicKey
        case .confirmTransaction:
            .confirmTransaction
        case let .other(description):
            .other(description: description)
        }
    }
}
