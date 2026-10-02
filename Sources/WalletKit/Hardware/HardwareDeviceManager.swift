//
//  HardwareDeviceManager.swift
//  WalletKit
//
//  Created by Andrey Yurkevich on 20/08/2026.
//  Copyright © 2026 Reefr Wallet. All rights reserved.
//

import class WalletKitRust.HardwareDeviceManagerFfi

/// Discovers and connects to hardware wallets.
public protocol HardwareDeviceManagerProtocol: AnyObject {
    /// Scans for connected/reachable hardware devices.
    ///
    /// - Parameters:
    ///   - vendors: Which manufacturers to look for.
    ///   - transports: Which transports to scan over. Must be non-empty.
    /// - Returns: Info for every discovered device.
    func scan(vendors: [HardwareVendor], transports: [HardwareTransportKind]) async throws -> [HardwareDeviceInfo]

    /// Connects to a previously discovered device.
    ///
    /// - Parameters:
    ///   - info: The device to connect to, as returned by
    ///     `scan(vendors:transports:)`.
    ///   - delegate: The delegate to relay input/confirmation requests and
    ///     disconnection events to.
    /// - Returns: The connected device.
    func connect(_ info: HardwareDeviceInfo, delegate: HardwareDeviceDelegate) async throws -> HardwareDevice
}

/// Discovers and connects to hardware wallets. Trezor is the only vendor
/// wired up today, over USB — and only on macOS, since Trezor devices
/// aren't MFi-certified and iOS has no generic USB HID access without it
/// (see `Docs/Overview.md`'s "Transport and platform constraints").
public final class HardwareDeviceManager: HardwareDeviceManagerProtocol {
    private let raw = HardwareDeviceManagerFfi()

    public init() {}

    /// Scans for connected/reachable hardware devices.
    ///
    /// - Parameters:
    ///   - vendors: Which manufacturers to look for. Defaults to every
    ///     supported vendor.
    ///   - transports: Which transports to scan over. Must be non-empty.
    ///     Defaults to USB and Bluetooth.
    /// - Returns: Info for every discovered device.
    /// - Throws: ``WalletKitError/transportUnavailable(reason:)`` if
    ///   `transports` is empty, or if USB isn't supported on this
    ///   platform.
    public func scan(
        vendors: [HardwareVendor] = HardwareVendor.allCases,
        transports: [HardwareTransportKind] = [.usb, .bluetooth]
    ) async throws -> [HardwareDeviceInfo] {
        let infos = try await remappingWalletKitError {
            try await raw.scan(vendors: vendors.map(\.raw), transports: transports.map(\.rawValue))
        }

        return infos.map(HardwareDeviceInfo.init(raw:))
    }

    /// Connects to a previously discovered device.
    ///
    /// - Parameters:
    ///   - info: The device to connect to, as returned by
    ///     `scan(vendors:transports:)`.
    ///   - delegate: The delegate to relay input/confirmation requests and
    ///     disconnection events to.
    /// - Returns: The connected device.
    /// - Throws: ``WalletKitError/deviceNotFound`` if `info` doesn't match
    ///   a device from a preceding `scan(vendors:transports:)` call, or another
    ///   hardware-wallet ``WalletKitError`` case if the connection
    ///   handshake fails.
    public func connect(_ info: HardwareDeviceInfo, delegate: HardwareDeviceDelegate) async throws -> HardwareDevice {
        let adapter = HardwareDeviceDelegateAdapter(delegate: delegate)
        let rawDevice = try await remappingWalletKitError { try await raw.connect(info: info.raw, delegate: adapter) }

        let device = HardwareDevice(raw: rawDevice, delegateAdapter: adapter)
        adapter.device = device
        return device
    }
}
