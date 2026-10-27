import Foundation
import WalletKitRust

/// A dapp-supplied Cardano transaction, decoded fail-closed from its CBOR for
/// the approval preview. Built from the original bytes, so the body hash is
/// the one a signer authorizes.
public struct CardanoDappTransaction: Equatable, Sendable {
    public struct Asset: Equatable, Sendable {
        public let name: Data
        public let policyId: Data
        /// Signed for mint entries: negative burns.
        public let quantity: String
    }

    public struct Certificate: Equatable, Sendable {
        public let kind: String
    }

    public struct Input: Equatable, Sendable {
        public let index: UInt32
        public let txHash: Data
    }

    public struct Output: Equatable, Sendable {
        public let address: String
        public let assets: [Asset]
        public let hasDatum: Bool
        public let hasReferenceScript: Bool
        public let lovelace: String
    }

    public struct Withdrawal: Equatable, Sendable {
        public let lovelace: String
        public let rewardAddress: String
    }

    public let auxiliaryDataHash: Data?
    public let bodyHash: Data
    public let certificates: [Certificate]
    public let collateral: [Input]
    public let fee: String
    public let hasScripts: Bool
    public let inputs: [Input]
    public let mint: [Asset]
    public let networkId: UInt8?
    public let outputs: [Output]
    public let referenceInputs: [Input]
    public let requiredSigners: [Data]
    public let ttl: String?
    public let validityStart: String?
    public let votingProcedureCount: Int
    public let votingProposalCount: Int
    public let withdrawals: [Withdrawal]

    /// - Throws: ``WalletKitError`` for malformed CBOR or trailing bytes.
    public init(decoding transaction: Data) throws {
        let raw = try remappingWalletKitError { try cardanoDecodeTransaction(transaction: transaction) }
        let asset = { (value: CardanoAssetFfi) in
            Asset(name: value.name, policyId: value.policyId, quantity: value.quantity)
        }

        let input = { (value: CardanoDappInputFfi) in Input(index: value.outputIndex, txHash: value.txHash) }
        let output = { (value: CardanoDappOutputFfi) in
            Output(
                address: value.address,
                assets: value.assets.map(asset),
                hasDatum: value.datumHash != nil || value.inlineDatum != nil,
                hasReferenceScript: value.hasReferenceScript,
                lovelace: value.lovelace
            )
        }

        auxiliaryDataHash = raw.auxiliaryDataHash
        bodyHash = raw.bodyHash
        certificates = raw.certificates.map { Certificate(kind: $0.kind) }
        collateral = raw.collateral.map(input)
        fee = raw.fee
        hasScripts = raw.hasScripts
        inputs = raw.inputs.map(input)
        mint = raw.mint.map(asset)
        networkId = raw.networkId
        outputs = raw.outputs.map(output)
        referenceInputs = raw.referenceInputs.map(input)
        requiredSigners = raw.requiredSigners
        ttl = raw.ttl
        validityStart = raw.validityStart
        votingProcedureCount = Int(raw.votingProcedureCount)
        votingProposalCount = Int(raw.votingProposalCount)
        withdrawals = raw.withdrawals.map { Withdrawal(lovelace: $0.lovelace, rewardAddress: $0.rewardAddress) }
    }
}
