//
//  TonPKeySigner.swift
//  WalletKit
//
//  Copyright © 2026 Reefr Wallet. All rights reserved.
//

import Foundation

/// A ``Signer`` backed by a software-held ed25519 ``PrivateKey``, for TON V5R1 wallets.
///
/// Signs the cell hash of the request body in a ``TonUnsignedTransaction`` envelope. There is no hardware
/// signer: Trezor has no TON app.
public final class TonPKeySigner: Signer {
    public typealias Address = TonAddress

    public let account: Account
    private let network: TonNetwork
    private let privateKey: PrivateKey

    /// - Throws: ``WalletKitError/unsupportedCurve(curve:)`` unless `privateKey` is ed25519.
    public init(network: TonNetwork = .mainnet, privateKey: PrivateKey, derivationPath: DerivationPath) throws {
        guard privateKey.curve == .ed25519 else {
            throw WalletKitError.unsupportedCurve(curve: privateKey.curve)
        }

        self.network = network
        self.privateKey = privateKey
        account = Account(
            blockchain: .ton(network),
            derivationPath: derivationPath,
            curve: .ed25519,
            source: .software,
            publicKey: privateKey.publicKey
        )
    }

    /// The V5R1 wallet address for ``account``'s key.
    public func address() throws -> TonAddress {
        try TonAddress(publicKey: account.publicKey, network: network)
    }

    /// Signs the hash of the request body in `transaction`.
    ///
    /// - Parameter transaction: The JSON envelope produced by ``TonTransactionBuilder``.
    /// - Returns: The raw 64-byte ed25519 signature.
    public func sign(transaction: Data) async throws -> Data {
        let envelope = try JSONDecoder().decode(TonUnsignedTransaction.self, from: transaction)

        guard envelope.network == network, try TonAddress(string: envelope.sender) == address() else {
            throw WalletKitError.signingFailed(reason: "the transaction is for another TON wallet or network")
        }

        return try privateKey.sign(message: envelope.signingHash())
    }
}
