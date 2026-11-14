//
//  TonJetton.swift
//  WalletKit
//
//  Copyright © 2026 Reefr Wallet. All rights reserved.
//

import BigInt
import Foundation

/// Message layouts of the Jetton standard (TEP-74).
enum TonJetton {
    /// `transfer#0f8a7ea5`: sent to the owner's Jetton wallet.
    static let transferOpcode: UInt64 = 0x0F8A_7EA5
    /// ``transferOpcode`` as toncenter reports a message's opcode.
    static let transferOpcodeText = "0x0f8a7ea5"
    static let internalTransferOpcodeText = "0x178d4519"

    /// `transfer_notification#7362d09c`: what the recipient's wallet sends its owner on credit.
    static let transferNotificationOpcode: UInt64 = 0x7362_D09C
    /// `internal_transfer#178d4519`: between two Jetton wallets.
    static let internalTransferOpcode: UInt64 = 0x178D_4519
    /// `excesses#d53276db`: returns the unused attached Gram to `response_destination`.
    static let excessesOpcode: UInt64 = 0xD532_76DB

    /// The body of a `transfer`: `amount` Jettons to the wallet of `destination`'s owner, with the unused attached
    /// Gram returned to `responseDestination`. `forwardAmount` nanograms and the optional text comment go to the
    /// recipient in a `transfer_notification`.
    static func transferBody(
        queryId: UInt64,
        amount: BigUInt,
        destination: TonAddress,
        responseDestination: TonAddress,
        forwardAmount: BigUInt,
        comment: String?
    ) throws -> TonCell {
        var builder = TonCellBuilder()
        builder.storeUInt(transferOpcode, bits: 32)
        builder.storeUInt(queryId, bits: 64)
        builder.storeCoins(amount)
        builder.storeAddress(destination)
        builder.storeAddress(responseDestination)
        builder.storeBit(false)
        builder.storeCoins(forwardAmount)

        if let comment, !comment.isEmpty {
            var text = TonCellBuilder()
            text.storeUInt(0, bits: 32)
            text.storeBytes(Data(comment.utf8))
            builder.storeInlineOrRef(try text.build())
        } else {
            builder.storeBit(false)
        }

        return try builder.build()
    }
}

/// The Jetton intent of a transfer, kept with the signed request so history and delivery tracking can tell the
/// token amount from the Gram attached to carry it.
public struct TonJettonTransfer: Codable, Equatable, Sendable {
    /// The token amount, in the Jetton's smallest unit.
    public let amount: String
    /// The Jetton master, as ``TonClient`` keys it.
    public let master: String
    public let queryId: UInt64
    /// The owner the tokens go to.
    public let recipient: String
    /// The sender's Jetton wallet, which receives the request.
    public let senderWallet: String

    public init(amount: String, master: String, queryId: UInt64, recipient: String, senderWallet: String) {
        self.amount = amount
        self.master = master
        self.queryId = queryId
        self.recipient = recipient
        self.senderWallet = senderWallet
    }
}
