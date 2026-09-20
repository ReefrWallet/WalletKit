//
//  HardwareDeviceInfo.swift
//  WalletKit
//
//  Created by Andrey Yurkevich on 20/08/2026.
//  Copyright © 2026 Reefr Wallet. All rights reserved.
//

import struct WalletKitRust.HardwareDeviceInfoFfi

/// Static, connection-independent metadata describing a discovered or
/// connected hardware device.
public struct HardwareDeviceInfo: Equatable {
    /// A stable identifier for this device, e.g. its USB serial number.
    public let id: String

    /// The device's manufacturer.
    public let vendor: HardwareVendor

    /// The transport this info was discovered/connected over.
    public let transport: HardwareTransportKind

    /// The device's model name, e.g. `"Trezor Model T"`.
    public let model: String

    /// The user-assigned label shown on the device, if any.
    public let label: String?

    /// The device's current firmware version string, if known.
    public let firmwareVersion: String?

    /// Whether the device's firmware is below the minimum version this
    /// library supports and should be updated before use.
    public let needsFirmwareUpdate: Bool

    /// Creates a hardware device info value.
    ///
    /// - Parameters:
    ///   - id: A stable identifier for this device, e.g. its USB serial
    ///     number.
    ///   - vendor: The device's manufacturer.
    ///   - transport: The transport this info was discovered/connected
    ///     over.
    ///   - model: The device's model name, e.g. `"Trezor Model T"`.
    ///   - label: The user-assigned label shown on the device, if any.
    ///   - firmwareVersion: The device's current firmware version string,
    ///     if known.
    ///   - needsFirmwareUpdate: Whether the device's firmware is below the
    ///     minimum version this library supports and should be updated
    ///     before use.
    public init(
        id: String,
        vendor: HardwareVendor,
        transport: HardwareTransportKind,
        model: String = "",
        label: String? = nil,
        firmwareVersion: String? = nil,
        needsFirmwareUpdate: Bool = false
    ) {
        self.id = id
        self.vendor = vendor
        self.transport = transport
        self.model = model
        self.label = label
        self.firmwareVersion = firmwareVersion
        self.needsFirmwareUpdate = needsFirmwareUpdate
    }

    init(raw: HardwareDeviceInfoFfi) {
        id = raw.id
        vendor = HardwareVendor(raw.vendor)
        transport = HardwareTransportKind(rawValue: raw.transport)!
        model = raw.model
        label = raw.label
        firmwareVersion = raw.firmwareVersion
        needsFirmwareUpdate = raw.needsFirmwareUpdate
    }

    var raw: HardwareDeviceInfoFfi {
        HardwareDeviceInfoFfi(
            id: id,
            vendor: vendor.raw,
            transport: transport.rawValue,
            model: model,
            label: label,
            firmwareVersion: firmwareVersion,
            needsFirmwareUpdate: needsFirmwareUpdate
        )
    }
}
