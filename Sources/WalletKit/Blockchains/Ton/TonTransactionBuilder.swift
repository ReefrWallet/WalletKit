//
//  TonTransactionBuilder.swift
//  WalletKit
//
//  Copyright © 2026 Reefr Wallet. All rights reserved.
//

import BigInt
import Foundation

/// Builds an unsigned V5R1 Gram or Jetton transfer for one account.
///
/// The builder reads the wallet's state and `seqno`; a wallet that is not deployed gets its `StateInit`
/// attached, so the first send deploys it. The result is a ``TonUnsignedTransaction`` JSON envelope.
/// A Jetton token (its master address) moves through the sender's Jetton wallet instead.
public struct TonTransactionBuilder: BlockchainTransactionBuilderProtocol, Sendable {
    public typealias Address = TonAddress

    /// The Gram attached to a Jetton transfer unless an option says otherwise: enough for the Jetton wallets'
    /// work including deploying the recipient's. What is unused returns to the sender.
    public static let defaultJettonAttachment = BigUInt(50_000_000)

    /// Attachments tried in turn when sizing a Jetton transfer by emulation: a transfer that deploys the recipient's
    /// Jetton wallet, or a Jetton with heavier contracts, may need more than the default.
    public static let jettonAttachmentSteps: [BigUInt] = [50_000_000, 100_000_000, 250_000_000]

    /// Kept free beyond a Gram transfer's amount for the sender wallet's own fees.
    public static let gramFeeReserve = BigUInt(10_000_000)

    /// Kept free beyond the attachment for the sender wallet's own fees.
    public static let jettonFeeReserve = BigUInt(10_000_000)

    /// How long a signed request stays valid.
    public static let requestLifetime: TimeInterval = 10 * 60

    private let client: TonClient
    private let publicKey: Data
    private let now: @Sendable () -> Date

    /// - Parameters:
    ///   - client: The client to read state from.
    ///   - publicKey: The account's raw ed25519 public key, needed for the deployment `StateInit`.
    public init(client: TonClient, publicKey: Data) {
        self.init(client: client, publicKey: publicKey, now: { Date() })
    }

    init(client: TonClient, publicKey: Data, now: @escaping @Sendable () -> Date) {
        self.client = client
        self.publicKey = publicKey
        self.now = now
    }

    public func makeAddress(_ string: String) throws -> TonAddress {
        try client.makeAddress(string)
    }

    public func buildTransfer(
        sender: TonAddress,
        recipient: TonAddress,
        amount: BigUInt,
        token: String?,
        options: [BlockchainTransactionBuilderOptions]
    ) async throws -> Data {
        try sender.validate(for: client.network)
        try recipient.validate(for: client.network)

        let walletHash = TonWalletV5R1.stateInit(publicKey: publicKey, network: client.network).hash

        guard sender.workchain == 0, sender.hash == walletHash else {
            throw WalletKitError.invalidAddress(reason: "the sender is not this key's V5R1 wallet")
        }

        let information = try await client.accountInformation(sender)
        let needsDeployment = try Self.needsDeployment(information.state)

        let payment: Payment

        if let token {
            payment = try await jettonPayment(
                token: token,
                sender: sender,
                recipient: recipient,
                amount: amount,
                balance: information.balance,
                options: options
            )
        } else {
            payment = try await gramPayment(
                to: recipient,
                amount: amount,
                balance: information.balance,
                options: options
            )
        }

        let seqno = try await client.seqno(sender)
        let validUntil = UInt32(now().timeIntervalSince1970 + Self.requestLifetime)
        let body = try TonWalletV5R1.signingBody(
            network: client.network,
            validUntil: validUntil,
            seqno: seqno,
            message: payment.message
        )

        let deployment = TonWalletV5R1.stateInit(publicKey: publicKey, network: client.network)
        let transaction = TonUnsignedTransaction(
            body: TonBOC.serialize(body),
            network: client.network,
            recipient: recipient.string,
            sender: sender.string,
            seqno: seqno,
            stateInit: needsDeployment ? TonBOC.serialize(deployment) : nil,
            validUntil: validUntil,
            value: String(payment.gram),
            baselineLt: information.lastTransactionLt ?? 0,
            jetton: payment.jetton
        )

        return try JSONEncoder().encode(transaction)
    }

    /// The wallet's one outgoing message and what it moves.
    private struct Payment {
        /// The Gram leaving the wallet: the transfer itself, or what a Jetton transfer carries.
        let gram: BigUInt
        let jetton: TonJettonTransfer?
        let message: TonCell
    }

    private static func needsDeployment(_ state: TonAccountState) throws -> Bool {
        switch state {
        case .active: false
        case .nonexistent, .uninitialized: true
        // A frozen wallet can't be deployed again; sending is refused until it is unfrozen.
        case .frozen: throw BlockchainTransactionBuilderError.insufficientFunds(reason: "The wallet is frozen.")
        }
    }

    private func gramPayment(
        to recipient: TonAddress,
        amount: BigUInt,
        balance: BigUInt,
        options: [BlockchainTransactionBuilderOptions]
    ) async throws -> Payment {
        // The wallet pays for the request even when it can't afford the payment, and then skips the payment.
        guard balance >= amount + (options.requiredGram ?? Self.gramFeeReserve) else {
            throw BlockchainTransactionBuilderError.insufficientFunds(reason: "Not enough Gram to send and cover fees.")
        }

        return Payment(
            gram: amount,
            jetton: nil,
            message: try TonWalletV5R1.transferMessage(
                to: recipient,
                amount: amount,
                bounce: try await bounceFlag(for: recipient, options: options),
                comment: options.comment
            )
        )
    }

    /// A Jetton transfer to the sender's Jetton wallet, after checking on-chain that it holds enough tokens and
    /// the wallet enough Gram to attach.
    private func jettonPayment(
        token: String,
        sender: TonAddress,
        recipient: TonAddress,
        amount: BigUInt,
        balance: BigUInt,
        options: [BlockchainTransactionBuilderOptions]
    ) async throws -> Payment {
        let master = try client.makeAddress(token)
        let senderWallet = try await client.jettonWalletAddress(owner: sender, master: master)
        let attachment = options.jettonAttachment ?? Self.defaultJettonAttachment

        guard let wallet = try await client.jettonWalletData(senderWallet, owner: sender, master: master),
              wallet.balance >= amount
        else {
            throw BlockchainTransactionBuilderError.insufficientFunds(reason: "Not enough tokens to send.")
        }

        guard balance >= options.requiredGram ?? attachment + Self.jettonFeeReserve else {
            throw BlockchainTransactionBuilderError.insufficientFunds(reason: "Not enough Gram to pay the fees.")
        }

        let queryId = UInt64.random(in: 1 ... UInt64.max)
        let body = try TonJetton.transferBody(
            queryId: queryId,
            amount: amount,
            destination: recipient,
            responseDestination: sender,
            forwardAmount: 1,
            comment: options.comment
        )

        return Payment(
            gram: attachment,
            jetton: TonJettonTransfer(
                amount: String(amount),
                master: master.string,
                queryId: queryId,
                recipient: recipient.string,
                senderWallet: senderWallet.string
            ),
            message: try TonWalletV5R1.internalMessage(to: senderWallet, amount: attachment, bounce: true, body: body)
        )
    }

    /// An explicit option wins, then the friendly address's tag. A raw address is bounceable only when its
    /// state was read and the account is deployed; a failed lookup is thrown, never defaulted.
    private func bounceFlag(
        for recipient: TonAddress,
        options: [BlockchainTransactionBuilderOptions]
    ) async throws -> Bool {
        if let forced = options.bounce {
            return forced
        }

        if let tagged = recipient.isBounceable {
            return tagged
        }

        let state = try await client.accountState(recipient)
        return state == .active
    }
}

private extension [BlockchainTransactionBuilderOptions] {
    var bounce: Bool? {
        for case let .tonBounce(value) in self {
            return value
        }

        return nil
    }

    var comment: String? {
        for case let .tonComment(value) in self {
            return value
        }

        return nil
    }

    var requiredGram: BigUInt? {
        for case let .tonRequiredGram(value) in self {
            return value
        }

        return nil
    }

    var jettonAttachment: BigUInt? {
        for case let .tonJettonAttachment(value) in self {
            return value
        }

        return nil
    }
}
