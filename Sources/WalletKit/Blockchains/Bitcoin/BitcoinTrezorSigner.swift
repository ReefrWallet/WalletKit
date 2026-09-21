//
//  BitcoinTrezorSigner.swift
//  WalletKit
//

import Foundation
import WalletKitRust

/// A ``Signer`` backed by a connected Trezor ``HardwareDevice``, for
/// Bitcoin.
///
/// Unlike ``EthereumTrezorSigner`` (one address, one device-read public
/// key), a Bitcoin account is identified by a whole ``BitcoinDescriptor``
/// spanning many addresses. Building one from the device needs two reads,
/// each its own device round-trip:
///  - the master public key at the root path (``PublicKeyFfi``, no chain
///    code) — hashed into ``BitcoinDescriptor/masterFingerprint(of:)``, the
///    same way ``BitcoinPKeySigner`` hashes a software seed's master key;
///  - the account-level xpub at
///    ``DerivationPath/bitcoinAccount(network:scriptType:accountIndex:)``
///    (`device.raw.bitcoinXpub(path:)`), which — unlike the raw
///    ``HardwareDevice/publicKey(path:curve:)`` read — keeps its chain
///    code, so ``BitcoinDescriptor`` can derive every external/change
///    address locally without a further device round-trip.
///
/// ``sign(transaction:)`` then hands the whole unsigned PSBT to the device
/// for its own interactive `SignTx`/`TxRequest`/`TxAck` flow, which reads
/// each input's owning key straight off the PSBT's own `bip32_derivation`/
/// `tap_key_origins` fields — no local per-input key derivation, unlike
/// ``BitcoinPKeySigner``.
public final class BitcoinTrezorSigner: Signer {
    public typealias Address = BitcoinDescriptor

    /// The account this signer signs for.
    public let account: WKAccount

    private let descriptor: BitcoinDescriptor
    private let device: HardwareDevice

    /// Creates a signer for a Bitcoin account of `scriptType` on
    /// `network`, reading its account-level xpub off `device` at
    /// ``DerivationPath/bitcoinAccount(network:scriptType:accountIndex:)``.
    ///
    /// - Throws: ``WalletKitError/deviceDisconnected`` if `device` isn't
    ///   connected, or ``WalletKitError/userCancelled``/
    ///   ``WalletKitError/userRejectedOnDevice`` if the user backs out of
    ///   either device read's confirmation prompt.
    public init(
        network: BitcoinNetwork,
        scriptType: BitcoinScriptType,
        accountIndex: UInt32 = 0,
        device: HardwareDevice
    ) async throws {
        let masterPublicKey = try await device.publicKey(path: DerivationPath(segments: []), curve: .secp256k1)
        let masterFingerprint = try BitcoinDescriptor.fingerprint(of: masterPublicKey)

        let accountDerivationPath = try DerivationPath.bitcoinAccount(
            network: network,
            scriptType: scriptType,
            accountIndex: accountIndex
        )
        let accountPathText = String(accountDerivationPath.string.dropFirst(2)) // drop the leading "m/".

        let xpub = try await remappingWalletKitError {
            try await device.raw.bitcoinXpub(path: accountDerivationPath)
        }

        let descriptor = try BitcoinDescriptor(
            xpub: xpub,
            scriptType: scriptType,
            network: network,
            masterFingerprint: masterFingerprint,
            accountPath: accountPathText
        )

        let accountPublicKey = try ExtendedKey.fromSerialized(xpub, curve: .secp256k1).publicKey

        self.descriptor = descriptor
        self.device = device
        account = WKAccount(
            blockchain: .bitcoin(network),
            derivationPath: accountDerivationPath,
            curve: .secp256k1,
            source: device.source,
            publicKey: accountPublicKey
        )
    }

    /// ``descriptor`` — the account this signer signs for.
    public func address() throws -> BitcoinDescriptor {
        descriptor
    }

    /// Signs `transaction` — unsigned PSBT bytes from
    /// ``BitcoinTransactionBuilder/buildTransfer(sender:recipient:amount:token:options:)``
    /// — on the connected Trezor, showing its decoded inputs/outputs on
    /// the device's trusted screen for the user to confirm.
    ///
    /// - Returns: The finalized, broadcastable raw transaction, ready for
    ///   ``BitcoinClient/broadcast(transaction:signature:)`` as its
    ///   `signature` parameter (`transaction` there is unused) — the
    ///   device streams the fully signed transaction back directly, so no
    ///   separate finalize step is needed the way
    ///   ``BitcoinPKeySigner/sign(transaction:)`` needs one.
    /// - Throws: ``WalletKitError/deviceDisconnected`` if the device goes
    ///   away mid-signature, ``WalletKitError/userCancelled``/
    ///   ``WalletKitError/userRejectedOnDevice`` if the user backs out, or
    ///   ``WalletKitError/signingFailed(reason:)`` if the device reports a
    ///   protocol-level failure.
    public func sign(transaction: Data) async throws -> Data {
        guard device.isConnected else {
            throw WalletKitError.deviceDisconnected
        }

        return try await remappingWalletKitError {
            try await device.raw.bitcoinSignPsbt(psbt: transaction, network: descriptor.network.raw)
        }
    }
}
