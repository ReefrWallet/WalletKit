//
//  TonUnsignedTransaction.swift
//  WalletKit
//
//  Copyright © 2026 Reefr Wallet. All rights reserved.
//

import Foundation

/// The JSON envelope ``TonTransactionBuilder`` returns as "unsigned transaction bytes": the V5R1 request body
/// the wallet signs, plus what the node needs to submit it.
///
/// The signer signs the hash of `body`; ``TonClient/broadcast(transaction:signature:)`` appends the signature to
/// the body and wraps it in an external message, adding `stateInit` when the wallet is not yet deployed.
public struct TonUnsignedTransaction: Codable, Equatable, Sendable {
    /// BoC of the request body, without the signature.
    public let body: Data
    public let network: TonNetwork
    public let recipient: String
    public let sender: String
    public let seqno: UInt32
    /// BoC of the wallet's `StateInit`, present only for the first send of an undeployed wallet.
    public let stateInit: Data?
    /// Unix time after which the wallet rejects the request.
    public let validUntil: UInt32
    /// The transferred amount, in nanograms.
    public let value: String

    public init(
        body: Data,
        network: TonNetwork,
        recipient: String,
        sender: String,
        seqno: UInt32,
        stateInit: Data?,
        validUntil: UInt32,
        value: String
    ) {
        self.body = body
        self.network = network
        self.recipient = recipient
        self.sender = sender
        self.seqno = seqno
        self.stateInit = stateInit
        self.validUntil = validUntil
        self.value = value
    }

    /// The 32 bytes the wallet's key signs.
    public func signingHash() throws -> Data {
        try TonBOC.parse(body).hash
    }

    /// The BoC of the signed external message, ready for `sendBoc`.
    public func signedMessage(signature: Data) throws -> Data {
        guard signature.count == 64 else {
            throw WalletKitError.signingFailed(reason: "expected a 64-byte ed25519 signature, got \(signature.count)")
        }

        let signedBody = try TonBOC.parse(body).appending(signature)
        let wallet = try TonAddress(string: sender)
        let deployment = try stateInit.map(TonBOC.parse)
        return TonBOC.serialize(try TonWalletV5R1.externalMessage(to: wallet, body: signedBody, stateInit: deployment))
    }

    /// The TEP-467 normalized hash of the signed external message, hex encoded: it ignores the state init, so it
    /// is known right after signing and matches the node's index once the message lands.
    public func normalizedHash(signature: Data) throws -> String {
        try TonWalletV5R1.normalizedHash(
            wallet: TonAddress(string: sender),
            body: TonBOC.parse(body).appending(signature)
        )
        .map { String(format: "%02x", $0) }
        .joined()
    }
}
