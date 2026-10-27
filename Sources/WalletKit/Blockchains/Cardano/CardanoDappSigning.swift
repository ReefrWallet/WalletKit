import Foundation
import WalletKitRust

/// A CIP-1852 key under an account: payment (`role` 0), change (1) or the
/// stake key (2, index 0).
public struct CardanoSigningPath: Hashable, Sendable {
    public let index: UInt32
    public let role: UInt32

    public init(index: UInt32, role: UInt32) {
        self.index = index
        self.role = role
    }

    init(_ raw: CardanoSigningPathFfi) {
        self.init(index: raw.index, role: raw.role)
    }

    var raw: CardanoSigningPathFfi {
        CardanoSigningPathFfi(index: index, role: role)
    }
}

/// What a dapp transaction needs from an account, from
/// ``CardanoClient/resolveSigners(transaction:owner:)``.
public struct CardanoSigners: Equatable, Sendable {
    /// Required keys with neither an owned key nor a valid witness.
    public let missingCount: Int
    /// Owned keys that must sign, excluding already-valid witnesses.
    public let toSign: [CardanoSigningPath]
    /// Requirements that couldn't be resolved to a credential or script.
    public let unresolved: [String]
    /// Pre-existing vkey witnesses whose signature verifies.
    public let validExistingCount: Int

    /// Nothing is missing or unresolved: signing completes the transaction.
    public var isComplete: Bool {
        missingCount == 0 && unresolved.isEmpty
    }

    init(_ raw: CardanoSignersFfi) {
        missingCount = raw.missing.count
        toSign = raw.toSign.map(CardanoSigningPath.init)
        unresolved = raw.unresolved
        validExistingCount = Int(raw.validExistingCount)
    }
}

/// A CIP-8 `signData` result: the `COSE_Sign1` signature and `COSE_Key`, CBOR.
public struct CardanoSignedData: Codable, Equatable, Sendable {
    public let key: Data
    public let signature: Data

    public init(key: Data, signature: Data) {
        self.key = key
        self.signature = signature
    }
}

/// Signs dapp (CIP-30) Cardano requests with an account's keys. Cardano's
/// BIP32-Ed25519 keys don't fit ``Signer``/``Account``, so software and
/// hardware signers share this protocol instead.
public protocol CardanoDappSigner {
    /// Signs the hash of `transaction`'s original body bytes with `paths` and
    /// returns a witness set holding only those new vkey witnesses.
    func signDappTransaction(_ transaction: Data, paths: [CardanoSigningPath]) async throws -> Data

    /// Signs `payload` un-hashed (CIP-8) with the key at `path`, which the
    /// caller has resolved from `address` (raw bytes).
    func signData(_ payload: Data, address: Data, path: CardanoSigningPath) async throws -> CardanoSignedData
}

/// Software Cardano signer over BIP-39 entropy.
public struct CardanoPKeySigner: CardanoDappSigner, Sendable {
    private let accountIndex: UInt32
    private let entropy: Data

    /// - Parameter path: The account path, `m/1852'/1815'/N'`.
    public init(entropy: Data, network: CardanoNetwork, path: DerivationPath) throws {
        try path.validate(for: .cardano(network))
        self.entropy = entropy
        accountIndex = path.segments[2].index
    }

    public func signDappTransaction(_ transaction: Data, paths: [CardanoSigningPath]) async throws -> Data {
        try remappingWalletKitError {
            try cardanoSignDappTransaction(
                entropy: entropy,
                accountIndex: accountIndex,
                signingPaths: paths.map(\.raw),
                transaction: transaction
            )
        }
    }

    public func signData(_ payload: Data, address: Data, path: CardanoSigningPath) async throws -> CardanoSignedData {
        let result = try remappingWalletKitError {
            try cardanoCip8SignData(
                entropy: entropy,
                accountIndex: accountIndex,
                signingPath: path.raw,
                address: address,
                payload: payload
            )
        }

        return CardanoSignedData(key: result.key, signature: result.signature)
    }
}

extension CardanoTrezorSigner: CardanoDappSigner {
    public func signDappTransaction(_ transaction: Data, paths: [CardanoSigningPath]) async throws -> Data {
        let xpub = try requireXpub()

        return try await remappingWalletKitError {
            try await device.raw.cardanoSignDappTx(
                transaction: transaction,
                accountPath: accountPath.raw,
                accountXpub: xpub,
                networkId: network.addressNetworkId,
                protocolMagic: network.protocolMagic,
                signingPaths: paths.map(\.raw)
            )
        }
    }

    public func signData(_ payload: Data, address: Data, path: CardanoSigningPath) async throws -> CardanoSignedData {
        let xpub = try requireXpub()

        let result = try await remappingWalletKitError {
            try await device.raw.cardanoSignMessage(
                address: address,
                payload: payload,
                accountPath: accountPath.raw,
                accountXpub: xpub,
                networkId: network.addressNetworkId,
                protocolMagic: network.protocolMagic,
                signingPath: path.raw
            )
        }

        return CardanoSignedData(key: result.key, signature: result.signature)
    }
}

/// Maps a `signData` address to the account key behind it; `nil` means the
/// account holds no such key (CIP-30 `DataSignError.AddressNotPK`).
public func cardanoSigningPath(
    for address: Data,
    owner: CardanoAccountDescriptor,
    usage: CardanoAddressUsage
) throws -> CardanoSigningPath? {
    try remappingWalletKitError {
        try cardanoClassifySigningAddress(address: address, accountXpub: owner.xpub, usedIndices: usage.indices)
    }
    .map(CardanoSigningPath.init)
}

/// Raw address bytes of a Cardano address, as CIP-30 exchanges them.
public func cardanoAddressBytes(_ address: String) throws -> Data {
    try remappingWalletKitError { try cardanoAddressToBytes(address: address) }
}

/// The bech32 form of raw Cardano address bytes.
public func cardanoAddressString(_ bytes: Data) throws -> String {
    try remappingWalletKitError { try cardanoAddressFromBytes(bytes: bytes) }
}
