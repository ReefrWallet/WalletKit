import BigInt
import Foundation
import WalletKitRust

/// The signed-body inputs needed to create Cardano witnesses.
public struct CardanoUnsignedTransaction: Codable, Sendable {
    public let fee: String
    public let inputs: [CardanoTransactionInputFfi]
    public let networkId: UInt8
    public let outputs: [CardanoTransactionOutputFfi]
    public let signingPaths: [CardanoSigningPathFfi]
    /// Set on staking transactions; a device signs those at transaction level.
    public let staking: CardanoStakingSummary?
    public let transactionBody: Data
    public let ttl: UInt64?

    public init(
        fee: String,
        inputs: [CardanoTransactionInputFfi],
        networkId: UInt8,
        outputs: [CardanoTransactionOutputFfi],
        signingPaths: [CardanoSigningPathFfi],
        staking: CardanoStakingSummary?,
        transactionBody: Data,
        ttl: UInt64?
    ) {
        self.fee = fee
        self.inputs = inputs
        self.networkId = networkId
        self.outputs = outputs
        self.signingPaths = signingPaths
        self.staking = staking
        self.transactionBody = transactionBody
        self.ttl = ttl
    }

    init(_ raw: CardanoUnsignedTransactionFfi, staking: CardanoStakingSummary? = nil) {
        fee = raw.fee
        inputs = raw.inputs
        networkId = raw.networkId
        outputs = raw.outputs
        signingPaths = raw.signingPaths
        self.staking = staking
        transactionBody = raw.transactionBody
        ttl = raw.ttl
    }

    /// - Parameters:
    ///   - entropy: The wallet's BIP-39 entropy, from which the keys derive.
    ///   - path: The signing account's path, `m/1852'/1815'/N'`.
    public func signed(entropy: Data, path: DerivationPath) throws -> Data {
        try signed(root: .bip39Entropy(entropy), path: path)
    }

    /// - Parameters:
    ///   - root: The wallet's secret, from which the keys derive.
    ///   - path: The signing account's path, `m/1852'/1815'/N'`.
    public func signed(root: CardanoRootSecret, path: DerivationPath) throws -> Data {
        try path.validate(for: .cardano(.mainnet)) // the path shape is network-independent
        return try remappingWalletKitError {
            try cardanoSignTransaction(
                root: root.raw,
                accountIndex: path.segments[2].index,
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

        return try JSONEncoder()
            .encode(CardanoUnsignedTransaction(
                try await client.buildTransfer(
                    account,
                    recipientLovelace: recipientLovelace,
                    recipient: address,
                    amount: amount,
                    token: token
                )
            ))
    }
}
