import BigInt
import Foundation
import WalletKitRust

/// The signed-body inputs a ``CardanoPKeySigner`` needs to create witnesses.
public struct CardanoUnsignedTransaction: Codable, Sendable {
    public let fee: String
    public let inputs: [CardanoTransactionInputFfi]
    public let networkID: UInt8
    public let outputs: [CardanoTransactionOutputFfi]
    public let signingPaths: [CardanoSigningPathFfi]
    public let transactionBody: Data
    public let ttl: UInt64?

    init(_ raw: CardanoUnsignedTransactionFfi) {
        fee = raw.fee
        inputs = raw.inputs
        networkID = raw.networkId
        outputs = raw.outputs
        signingPaths = raw.signingPaths
        transactionBody = raw.transactionBody
        ttl = raw.ttl
    }

    public func signed(entropy: Data, accountIndex: UInt32) throws -> Data {
        try remappingWalletKitError {
            try cardanoSignTransaction(
                entropy: entropy,
                accountIndex: accountIndex,
                signingPaths: signingPaths,
                transactionBody: transactionBody
            )
        }
    }

    /// Combines device-produced verification-key witnesses with this exact
    /// canonical transaction body.
    public func assembled(witnesses: [CardanoWitnessFfi]) throws -> Data {
        try remappingWalletKitError {
            try cardanoAssembleTransaction(transactionBody: transactionBody, witnesses: witnesses)
        }
    }

    func transactionBodyHash() throws -> Data {
        try remappingWalletKitError {
            try cardanoTransactionBodyHash(transactionBody: transactionBody)
        }
    }
}

/// Constructs native ADA transfers from the account's current receive UTxOs.
public struct CardanoTransactionBuilder: BlockchainTransactionBuilderProtocol, Sendable {
    public typealias Address = CardanoTransactionAddress

    private let client: CardanoClient

    public init(client: CardanoClient) {
        self.client = client
    }

    public func buildTransfer(
        sender: CardanoTransactionAddress,
        recipient: CardanoTransactionAddress,
        amount: BigUInt,
        token: String?,
        options: [BlockchainTransactionBuilderOptions]
    ) async throws -> Data {
        guard case let .account(account) = sender else {
            throw WalletKitError.invalidAddress(reason: "Cardano sender must be an account descriptor.")
        }
        guard case let .recipient(address) = recipient else {
            throw WalletKitError.invalidAddress(reason: "Cardano recipient must be a payment address.")
        }
        guard account.network == address.network else {
            throw WalletKitError.invalidAddress(reason: "Cardano sender and recipient networks differ.")
        }

        let recipientLovelace = options.compactMap { option -> UInt64? in
            guard case let .cardanoRecipientLovelace(value) = option else {
                return nil
            }
            return value
        }.last
        return try JSONEncoder().encode(CardanoUnsignedTransaction(try await client.buildTransfer(
            account,
            recipientLovelace: recipientLovelace,
            recipient: address,
            amount: amount,
            token: token
        )))
    }
}
