//
//  HardwareKeyBatch.swift
//  WalletKit
//
//  Created by Andrey Yurkevich on 26/11/2026.
//  Copyright © 2026 Reefr Wallet. All rights reserved.
//

import class WalletKitRust.HardwareBatchTokenFfi
import enum WalletKitRust.HardwareKeyRequestFfi
import enum WalletKitRust.HardwareKeyResponseFfi

/// One read of a ``HardwareDevice/readKeys(_:)`` batch.
public enum HardwareKeyRequest: Hashable, Sendable {
    /// The Cardano account extended public key at the path, as
    /// ``HardwareDevice/cardanoXpub(path:)`` reads it.
    case cardanoXpub(DerivationPath)
    /// The secp256k1 extended public key at the path, `xpub`-serialized
    /// whatever the chain, for deriving non-hardened children locally with
    /// ``ExtendedKey/fromSerialized(_:curve:)``.
    case extendedPublicKey(DerivationPath)
    /// The public key at the path for the curve.
    case publicKey(DerivationPath, Curve)

    var raw: HardwareKeyRequestFfi {
        switch self {
        case let .cardanoXpub(path): .cardanoXpub(path: path.raw)
        case let .extendedPublicKey(path): .extendedPublicKey(path: path.raw)
        case let .publicKey(path, curve): .publicKey(path: path.raw, curve: curve.raw)
        }
    }
}

/// The answer to one ``HardwareKeyRequest``, of the matching kind.
public enum HardwareKeyResponse {
    case cardanoXpub(String)
    case extendedPublicKey(String)
    case publicKey(PublicKey)

    init(raw: HardwareKeyResponseFfi) {
        switch raw {
        case let .cardanoXpub(xpub): self = .cardanoXpub(xpub)
        case let .extendedPublicKey(xpub): self = .extendedPublicKey(xpub)
        case let .publicKey(key): self = .publicKey(PublicKey(raw: key))
        }
    }

    /// The xpub of a `.cardanoXpub` or `.extendedPublicKey` answer.
    public var xpub: String? {
        switch self {
        case let .cardanoXpub(xpub), let .extendedPublicKey(xpub): xpub
        case .publicKey: nil
        }
    }

    /// The key of a `.publicKey` answer.
    public var publicKey: PublicKey? {
        guard case let .publicKey(key) = self else {
            return nil
        }

        return key
    }
}

public extension HardwareDevice {
    /// Reads `requests` back to back as one device command, answering in
    /// order. A PIN or passphrase prompt happens at most once, and no other
    /// command runs in between.
    ///
    /// Cancelling the calling task stops only this batch, before its next
    /// read (or before it starts), with ``WalletKitError/userCancelled``,
    /// without waiting for it.
    ///
    /// - Throws: The errors ``publicKey(path:curve:)`` and
    ///   ``cardanoXpub(path:)`` throw.
    func readKeys(_ requests: [HardwareKeyRequest]) async throws -> [HardwareKeyResponse] {
        let raw = raw
        let token = HardwareBatchTokenFfi()

        return try await withTaskCancellationHandler {
            try await remappingWalletKitError {
                try await raw.readKeys(requests: requests.map(\.raw), token: token).map(HardwareKeyResponse.init(raw:))
            }
        } onCancel: {
            token.cancel()
        }
    }

    /// Stops ``readKeys(_:)`` batches issued so far at their next read.
    func cancelPendingReads() {
        raw.cancelPending()
    }
}
