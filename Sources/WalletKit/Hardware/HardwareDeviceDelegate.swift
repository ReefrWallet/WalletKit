//
//  HardwareDeviceDelegate.swift
//  WalletKit
//
//  Created by Andrey Yurkevich on 20/08/2026.
//  Copyright © 2026 Reefr Wallet. All rights reserved.
//

import WalletKitRust

/// Callbacks a ``HardwareDevice`` uses to relay user-interaction requests
/// and lifecycle events back to the app.
public protocol HardwareDeviceDelegate: AnyObject {
    /// Called when `device` needs the user to provide a piece of input
    /// (a PIN or passphrase).
    ///
    /// - Parameters:
    ///   - device: The device requesting input.
    ///   - request: What kind of input is being requested.
    /// - Returns: The user-provided value, or `nil` if the user cancelled.
    func hardwareDevice(_ device: HardwareDevice, needsInput request: HardwareInputRequest) async -> String?

    /// Called when `device` is waiting for the user to physically confirm
    /// something on the device itself.
    ///
    /// - Parameters:
    ///   - device: The device waiting for confirmation.
    ///   - request: What's being confirmed.
    func hardwareDevice(_ device: HardwareDevice, waitingForConfirmation request: HardwareButtonRequest) async

    /// Called when `device` disconnects, whether initiated by the app
    /// (``HardwareDevice/disconnect()``) or externally (e.g. the user
    /// unplugged it).
    ///
    /// - Parameter device: The device that disconnected.
    func hardwareDeviceDidDisconnect(_ device: HardwareDevice)
}

/// Bridges a Swift-implemented ``HardwareDeviceDelegate`` — whose methods
/// are all scoped to a particular ``HardwareDevice`` — to the generated
/// `HardwareDeviceDelegateFfi` callback interface Rust actually calls
/// into, which carries no device identity of its own (one delegate is
/// bound to one device at connection time, so Rust doesn't need to pass
/// it back). `device` is set once the ``HardwareDevice`` it's attached to
/// exists — necessarily after this adapter is already handed to
/// `HardwareDeviceManagerFfi.connect`, since that call is what produces
/// the device.
///
/// Both references are `weak`: the app owns ``HardwareDeviceDelegate``
/// and ``HardwareDevice`` owns this adapter, so holding either strongly
/// here would create a retain cycle.
final class HardwareDeviceDelegateAdapter: HardwareDeviceDelegateFfi, @unchecked Sendable {
    private weak var delegate: HardwareDeviceDelegate?
    weak var device: HardwareDevice?

    init(delegate: HardwareDeviceDelegate) {
        self.delegate = delegate
    }

    func needsInput(request: HardwareInputRequestFfi) async -> String? {
        guard let delegate, let device else {
            return nil
        }

        return await delegate.hardwareDevice(device, needsInput: HardwareInputRequest(raw: request))
    }

    func waitingForConfirmation(request: HardwareButtonRequestFfi) async {
        guard let delegate, let device else {
            return
        }

        await delegate.hardwareDevice(device, waitingForConfirmation: HardwareButtonRequest(raw: request))
    }

    func didDisconnect() async {
        guard let delegate, let device else {
            return
        }

        delegate.hardwareDeviceDidDisconnect(device)
    }
}
