//
//  BitcoinPKeySigner.swift
//  WalletKit
//

import Foundation
import WalletKitRust

/// A ``Signer`` backed directly by a software-held ``Seed``, for Bitcoin.
///
/// Unlike ``EthereumPKeySigner``/``SuiPKeySigner`` (one address, one
/// private key), a Bitcoin account's descriptor spans many addresses —
/// each PSBT input can be owned by a different derived key. So
/// ``sign(transaction:)`` re-derives one private key per input, reading
/// each input's own recorded BIP-32 path back off the PSBT via
/// `bitcoinPsbtInputDerivations` (which is why it needs a whole ``Seed``,
/// not one ``PrivateKey``, at construction).
public final class BitcoinPKeySigner: Signer {
    public typealias Address = BitcoinDescriptor

    /// The account this signer signs for.
    public let account: WKAccount

    private let descriptor: BitcoinDescriptor
    private let seed: Seed

    /// Creates a signer for `descriptor`, deriving per-input keys from
    /// `seed`.
    ///
    /// - Parameters:
    ///   - descriptor: The account descriptor (`wpkh(...)`/`tr(...)`)
    ///     this signer signs for.
    ///   - seed: The seed to derive per-input private keys from.
    ///   - derivationPath: The account-level path `descriptor`'s xpub was
    ///     derived at — see
    ///     ``DerivationPath/bitcoinAccount(network:scriptType:accountIndex:)``.
    /// - Throws: ``WalletKitError/keyNotFound`` if `descriptor` is
    ///   `.singleAddress` — a watch-only descriptor has no keys to sign
    ///   with.
    public init(descriptor: BitcoinDescriptor, seed: Seed, derivationPath: DerivationPath) throws {
        guard descriptor.scriptType != .singleAddress else {
            throw WalletKitError.keyNotFound
        }

        self.descriptor = descriptor
        self.seed = seed

        let accountPublicKey = try seed.masterKey(curve: .secp256k1).derive(derivationPath).publicKey
        account = WKAccount(
            blockchain: .bitcoin(descriptor.network),
            derivationPath: derivationPath,
            curve: .secp256k1,
            source: .software,
            publicKey: accountPublicKey
        )
    }

    /// ``descriptor`` — the account this signer signs for.
    public func address() throws -> BitcoinDescriptor {
        descriptor
    }

    /// Signs `transaction` — unsigned PSBT bytes from
    /// ``BitcoinTransactionBuilder/buildTransfer(sender:recipient:amount:token:options:)``.
    ///
    /// Reads back each input's own recorded derivation path
    /// (`bitcoinPsbtInputDerivations`), derives the matching private key
    /// from ``seed``, signs (`BitcoinSignerFfi.signPsbt`), and finalizes
    /// (`.finalizePsbt`) — returning the finalized, broadcastable raw
    /// transaction ready for ``BitcoinClient/broadcast(transaction:signature:)``
    /// (as its `signature` parameter; `transaction` there is unused).
    ///
    /// - Throws: ``WalletKitError/signingFailed(reason:)`` if
    ///   `transaction` isn't a well-formed PSBT built by this crate, or a
    ///   derived key doesn't own the input it's positioned at (e.g.
    ///   `seed` doesn't match the descriptor that built this PSBT).
    public func sign(transaction: Data) async throws -> Data {
        let derivations = try remappingWalletKitError { try bitcoinPsbtInputDerivations(psbt: transaction) }
        let masterKey = try seed.masterKey(curve: .secp256k1)

        let keys: [PrivateKey] = try derivations.map { derivation in
            let path = try DerivationPath(string: "m/\(derivation.derivationPath)")
            return try masterKey.derive(path).privateKey()
        }

        let signer = BitcoinSignerFfi()
        let signed = try remappingWalletKitError { try signer.signPsbt(psbt: transaction, keys: keys.map(\.raw)) }
        return try remappingWalletKitError { try signer.finalizePsbt(psbt: signed) }
    }
}
