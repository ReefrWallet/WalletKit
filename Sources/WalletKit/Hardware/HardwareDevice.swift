//
//  HardwareDevice.swift
//  WalletKit
//
//  Created by Andrey Yurkevich on 20/08/2026.
//  Copyright © 2026 Reefr Wallet. All rights reserved.
//

import class WalletKitRust.HardwareDeviceFfi

/// A connected hardware wallet.
///
/// Obtained from ``HardwareDeviceManager/connect(_:delegate:)``.
public final class HardwareDevice: HardwareDeviceProtocol {
    /// Static metadata describing this device, snapshotted at connect time.
    public let info: HardwareDeviceInfo

    let raw: HardwareDeviceFfi
    private let delegateAdapter: HardwareDeviceDelegateAdapter

    init(raw: HardwareDeviceFfi, delegateAdapter: HardwareDeviceDelegateAdapter) {
        self.raw = raw
        self.info = HardwareDeviceInfo(raw: raw.info())
        self.delegateAdapter = delegateAdapter
    }

    /// Whether this device is still connected.
    public var isConnected: Bool { raw.isConnected() }

    /// Where this device's key material lives — always
    /// ``KeySource/hardware(_:)`` with this device's ``info``.
    public var source: KeySource { .hardware(info) }

    /// Reads the public key at `path` for `curve` from the device.
    ///
    /// - Parameters:
    ///   - path: The derivation path to read the public key at.
    ///   - curve: The elliptic curve to derive under.
    /// - Returns: The public key at `path`.
    /// - Throws: ``WalletKitError/unsupportedDevice(reason:)`` for a curve
    ///   this device can't derive (Trezor only supports secp256k1 today),
    ///   ``WalletKitError/deviceDisconnected`` if the device has gone
    ///   away, or ``WalletKitError/userCancelled``/
    ///   ``WalletKitError/userRejectedOnDevice`` if the user backs out of
    ///   a PIN/passphrase/confirmation prompt.
    public func publicKey(path: DerivationPath, curve: Curve) async throws -> PublicKey {
        try await remappingWalletKitError { PublicKey(raw: try await raw.publicKey(path: path.raw, curve: curve.raw)) }
    }

    /// Reads the Cardano Icarus/CIP-1852 account extended public key.
    public func cardanoXpub(path: DerivationPath) async throws -> String {
        try await remappingWalletKitError { try await raw.cardanoXpub(path: path.raw) }
    }

    /// Builds the ``Account`` for `blockchain` at index `account` from the
    /// device.
    ///
    /// - Parameters:
    ///   - blockchain: The blockchain to build the account for.
    ///   - account: The BIP44-style account index.
    /// - Returns: The resulting account, including its derived public key.
    public func account(_ blockchain: Blockchain, account: UInt32 = 0) async throws -> Account {
        let curve = Self.curve(for: blockchain)
        let path = try DerivationPath(blockchain, accountIndex: UInt64(account), curve: curve)
        let key = try await publicKey(path: path, curve: curve)
        return Account(blockchain: blockchain, derivationPath: path, curve: curve, source: source, publicKey: key)
    }

    /// Disconnects from this device and notifies the delegate.
    public func disconnect() async {
        await raw.disconnect()
    }

    private static func curve(for blockchain: Blockchain) -> Curve {
        switch blockchain {
        case .aptos, .sui: .ed25519
        case .solana, .cardano: .ed25519
        case .bitcoin, .evm, .tron: .secp256k1
        }
    }
}

public extension HardwareDeviceInfo {
    init(_ vendor: HardwareVendor, deviceId: String, transport: HardwareTransportKind = .usb) {
        self.init(
            id: deviceId,
            vendor: vendor,
            transport: transport,
            model: "",
            label: nil,
            firmwareVersion: nil,
            needsFirmwareUpdate: false
        )
    }
}
