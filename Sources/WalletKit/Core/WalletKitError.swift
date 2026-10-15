//
//  WalletKitError.swift
//  WalletKit
//
//  Created by Andrey Yurkevich on 16/08/2026.
//

import WalletKitRust

// MARK: - Errors

/// The single error type covering every failure WalletKit's software
/// key-management and hardware-device APIs can throw.
public enum WalletKitError: Error, Equatable {
    /// A mnemonic phrase failed to parse — malformed for its wordlist, or
    /// failed the BIP39 checksum. `reason` describes what went wrong.
    case invalidMnemonic(reason: String)

    /// Entropy supplied for mnemonic generation/import was invalid.
    case invalidEntropy

    /// A BIP39 passphrase (the "25th word") was invalid.
    case invalidPassphrase

    /// A derivation path string failed to parse, or a derivation step was
    /// out of range. `path` is the offending path or serialized key
    /// string.
    case invalidDerivationPath(path: String)

    /// An address string or raw byte encoding was invalid. `reason`
    /// describes what went wrong.
    case invalidAddress(reason: String)

    /// This feature is not supported
    case unsupportedFeature

    /// An operation was attempted on a curve it doesn't support (e.g.
    /// deriving an Ethereum address from an ed25519 key).
    case unsupportedCurve(curve: Curve)

    /// A big-integer conversion couldn't be represented in the requested
    /// integer type (negative magnitude for an unsigned type, or a value
    /// too large/small for the target's bit width). `reason` describes
    /// what went wrong.
    case invalidBigInt(reason: String)

    /// Raw seed bytes couldn't be reconstructed into a ``Seed`` — the byte
    /// count didn't match the expected 64-byte BIP39 seed size. `reason`
    /// describes what went wrong.
    case invalidSeed(reason: String)

    /// A mnemonic word count wasn't a supported BIP39 word count (12, 15,
    /// 18, 21, or 24).
    case unsupportedWordCount(count: UInt32)

    /// Signing or signature-related key construction failed. `reason`
    /// describes what went wrong.
    case signingFailed(reason: String)

    /// An operation needed a private key that isn't available (e.g. on a
    /// public-only/watch-only extended key).
    case keyNotFound

    /// A decryption operation failed.
    case decryptionFailed

    /// An unexpected internal failure occurred. `message` carries
    /// diagnostic detail; this case shouldn't normally surface from
    /// correct usage.
    case internalError(message: String)

    /// No hardware device matched the request.
    case deviceNotFound

    /// The hardware device disconnected mid-operation.
    case deviceDisconnected

    /// The hardware device is locked (e.g. awaiting PIN entry) and can't
    /// service the request.
    case deviceLocked

    /// The hardware device is busy with another operation.
    case deviceBusy

    /// The user rejected the operation on the device itself.
    case userRejectedOnDevice

    /// The user cancelled a host-side prompt (PIN or passphrase entry)
    /// instead of providing a value.
    case userCancelled

    /// The requested transport (USB, Bluetooth, ...) isn't available.
    /// `reason` describes why.
    case transportUnavailable(reason: String)

    /// The connected device isn't supported. `reason` describes why.
    case unsupportedDevice(reason: String)

    /// The device's firmware is below the minimum version this library
    /// supports. `minimumVersion` is the required version string.
    case firmwareOutdated(minimumVersion: String)

    /// Wraps the raw FFI error into its corresponding public case.
    init(_ raw: WalletKitErrorFfi) {
        switch raw {
        case .InvalidMnemonic(let reason): self = .invalidMnemonic(reason: reason)
        case .InvalidEntropy: self = .invalidEntropy
        case .InvalidPassphrase: self = .invalidPassphrase
        case .InvalidDerivationPath(let path): self = .invalidDerivationPath(path: path)
        case .InvalidAddress(let reason): self = .invalidAddress(reason: reason)
        case .UnsupportedCurve(let curve): self = .unsupportedCurve(curve: Curve(curve))
        case .InvalidBigInt(let reason): self = .invalidBigInt(reason: reason)
        case .InvalidSeed(let reason): self = .invalidSeed(reason: reason)
        case .UnsupportedWordCount(let count): self = .unsupportedWordCount(count: count)
        case .SigningFailed(let reason): self = .signingFailed(reason: reason)
        case .KeyNotFound: self = .keyNotFound
        case .DecryptionFailed: self = .decryptionFailed
        case .InternalError(let message): self = .internalError(message: message)
        case .DeviceNotFound: self = .deviceNotFound
        case .DeviceDisconnected: self = .deviceDisconnected
        case .DeviceLocked: self = .deviceLocked
        case .DeviceBusy: self = .deviceBusy
        case .UserRejectedOnDevice: self = .userRejectedOnDevice
        case .UserCancelled: self = .userCancelled
        case .TransportUnavailable(let reason): self = .transportUnavailable(reason: reason)
        case .UnsupportedDevice(let reason): self = .unsupportedDevice(reason: reason)
        case .FirmwareOutdated(let minimumVersion): self = .firmwareOutdated(minimumVersion: minimumVersion)
        }
    }
}

/// Runs `body`, translating any thrown `WalletKitErrorFfi` (from the raw
/// generated bindings) into the public ``WalletKitError``.
///
/// - Parameter body: The FFI-calling closure to run.
/// - Returns: `body`'s result, unchanged.
/// - Throws: ``WalletKitError`` if `body` throws a `WalletKitErrorFfi`;
///   otherwise rethrows whatever `body` threw.
func remappingWalletKitError<T>(_ body: () throws -> T) rethrows -> T {
    do {
        return try body()
    } catch let error as WalletKitErrorFfi {
        throw WalletKitError(error)
    }
}

/// The `async` counterpart of ``remappingWalletKitError(_:)``, for
/// hardware-device operations that need to await device I/O.
///
/// - Parameter body: The FFI-calling closure to run.
/// - Returns: `body`'s result, unchanged.
/// - Throws: ``WalletKitError`` if `body` throws a `WalletKitErrorFfi`;
///   otherwise rethrows whatever `body` threw.
func remappingWalletKitError<T>(_ body: () async throws -> T) async rethrows -> T {
    do {
        return try await body()
    } catch let error as WalletKitErrorFfi {
        throw WalletKitError(error)
    }
}

extension WalletKitError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case let .internalError(message): message
        case let .signingFailed(reason): reason
        default: nil
        }
    }
}
