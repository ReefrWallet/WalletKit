//
//  HardwareDeviceProtocol.swift
//  WalletKit
//
//  Created by Andrey Yurkevich on 20/08/2026.
//  Copyright © 2026 Reefr Wallet. All rights reserved.
//

/// A connected hardware wallet — a source of public keys and accounts,
/// read from the device rather than derived in-app.
public protocol HardwareDeviceProtocol: AnyObject {
    /// Static metadata describing this device.
    var info: HardwareDeviceInfo { get }

    /// Whether this device is still connected.
    var isConnected: Bool { get }

    /// Where this device's key material lives — always
    /// ``KeySource/hardware(_:)`` with this device's ``info``.
    var source: KeySource { get }

    /// Reads the public key at `path` for `curve` from the device.
    ///
    /// - Parameters:
    ///   - path: The derivation path to read the public key at.
    ///   - curve: The elliptic curve to derive under.
    /// - Returns: The public key at `path`.
    func publicKey(path: DerivationPath, curve: Curve) async throws -> PublicKey

    /// Builds the ``Account`` for `blockchain` at index `account` from the
    /// device.
    ///
    /// - Parameters:
    ///   - blockchain: The blockchain to build the account for.
    ///   - account: The BIP44-style account index.
    /// - Returns: The resulting account, including its derived public key.
    func account(_ blockchain: Blockchain, account: UInt32) async throws -> Account

    /// Disconnects from this device.
    func disconnect() async
}
