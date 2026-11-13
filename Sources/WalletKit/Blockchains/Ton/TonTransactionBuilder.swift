//
//  TonTransactionBuilder.swift
//  WalletKit
//
//  Copyright © 2026 Reefr Wallet. All rights reserved.
//

import BigInt
import Foundation

/// Builds an unsigned V5R1 Gram transfer for one account.
///
/// The builder reads the wallet's state and `seqno`; a wallet that is not deployed gets its `StateInit`
/// attached, so the first send deploys it. The result is a ``TonUnsignedTransaction`` JSON envelope.
/// Jettons are not supported yet.
public struct TonTransactionBuilder: BlockchainTransactionBuilderProtocol, Sendable {
    public typealias Address = TonAddress

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
        guard token == nil else {
            throw BlockchainTransactionBuilderError.invalidToken(reason: "TON Jettons are not supported yet")
        }

        try sender.validate(for: client.network)
        try recipient.validate(for: client.network)

        let walletHash = TonWalletV5R1.stateInit(publicKey: publicKey, network: client.network).hash

        guard sender.workchain == 0, sender.hash == walletHash else {
            throw WalletKitError.invalidAddress(reason: "the sender is not this key's V5R1 wallet")
        }

        let information = try await client.accountInformation(sender)

        guard information.balance >= amount else {
            throw BlockchainTransactionBuilderError.insufficientFunds(reason: "Not enough Gram to send.")
        }

        let needsDeployment: Bool

        switch information.state {
        case .active: needsDeployment = false
        case .nonexistent, .uninitialized: needsDeployment = true
        // A frozen wallet can't be deployed again; sending is refused until it is unfrozen.
        case .frozen: throw BlockchainTransactionBuilderError.insufficientFunds(reason: "The wallet is frozen.")
        }

        let seqno = try await client.seqno(sender)
        let bounce = try await bounceFlag(for: recipient, options: options)
        let message = try TonWalletV5R1.transferMessage(
            to: recipient,
            amount: amount,
            bounce: bounce,
            comment: options.comment
        )

        let validUntil = UInt32(now().timeIntervalSince1970 + Self.requestLifetime)
        let body = try TonWalletV5R1.signingBody(
            network: client.network,
            validUntil: validUntil,
            seqno: seqno,
            message: message
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
            value: String(amount)
        )

        return try JSONEncoder().encode(transaction)
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
}
