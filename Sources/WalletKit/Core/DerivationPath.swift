//
//  DerivationPath.swift
//  WalletKit
//
//  Created by Andrey Yurkevich on 16/08/2026.
//

import WalletKitRust

/// A BIP32 or SLIP-0010 derivation path.
///
/// Create a path from its segments with ``init(segments:)``, parse a
/// standard path string with ``init(string:)``, or use
/// ``init(_:accountIndex:curve:)`` for a blockchain's conventional account
/// path.
public struct DerivationPath: Codable, Equatable, Hashable, Sendable {
    let raw: DerivationPathFfi

    /// The ordered segments that make up this path.
    public var segments: [Segment] { raw.segments }

    /// Creates a derivation path from ordered segments.
    ///
    /// An empty array denotes the master key. Use ``init(string:)`` when the
    /// path originates as a standard `m/...` string.
    public init(segments: [Segment]) {
        raw = DerivationPathFfi(segments: segments)
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(segments: try container.decode([Segment].self, forKey: .segments))
    }

    /// Creates the conventional account path for a blockchain.
    ///
    /// - Parameters:
    ///   - blockchain: The blockchain the account belongs to.
    ///   - accountIndex: The account's zero-based index.
    ///   - curve: The curve used for the account's keys.
    /// - Throws: ``WalletKitError/invalidDerivationPath(path:)`` when the
    ///   resulting path is invalid, or ``WalletKitError/internalError(message:)``
    ///   when the blockchain requires a specialized path.
    public init(_ blockchain: Blockchain, accountIndex: UInt64, curve: Curve) throws {
        switch blockchain {
        case .evm:
            try self.init(string: "m/44'/60'/0'/0/\(accountIndex)")
        case .tron:
            try self.init(string: "m/44'/195'/0'/0/\(accountIndex)")
        case .solana:
            // SLIP-44 coin type 501, SLIP-10 ed25519 — every segment must
            // be hardened, matching Phantom/Trezor Suite's convention.
            try self.init(string: "m/44'/501'/\(accountIndex)'/0'")
        case .sui:
            // Sui wallet standard: purpose 44' for Ed25519, 54' for secp256k1.
            let purpose: UInt32
            switch curve {
            case .ed25519:
                purpose = 44
            case .secp256k1:
                purpose = 54
            }
            try self.init(string: "m/\(purpose)'/784'/0'/0'/\(accountIndex)'")
        case .bitcoin:
            throw WalletKitError.internalError(
                message: "Bitcoin has no single derivation path — use DerivationPath.bitcoinAccount(network:scriptType:accountIndex:) instead"
            )
        default:
            throw WalletKitError.internalError(message: "Unsupported blockchain: \(blockchain)")
        }
    }

    /// The BIP-84 (`m/84'/{0|1}'/{accountIndex}'`) or BIP-86
    /// (`m/86'/{0|1}'/{accountIndex}'`) account-level path for a Bitcoin
    /// account — where a ``BitcoinDescriptor``'s xpub sits, not a full
    /// address path. Bitcoin derives external/change addresses
    /// non-hardened below this via
    /// ``BitcoinDescriptor/deriveAddress(chain:index:)``, not through
    /// a plain ``DerivationPath`` the way EVM/Sui do — this is why
    /// ``init(_:accountIndex:curve:)`` throws for `.bitcoin` instead of
    /// handling it.
    ///
    /// - Parameters:
    ///   - network: Selects the coin type — `0'` for `.mainnet`, `1'` for
    ///     any test network (testnet/signet/regtest all conventionally
    ///     share coin type `1'` per SLIP-44).
    ///   - scriptType: Selects BIP-84 (`.p2wpkh`) or BIP-86 (`.p2tr`).
    ///   - accountIndex: The account's zero-based index.
    public static func bitcoinAccount(
        network: BitcoinNetwork,
        scriptType: BitcoinScriptType,
        accountIndex: UInt32
    ) throws -> DerivationPath {
        let purpose: UInt32
        switch scriptType {
        case .p2wpkh: purpose = 84
        case .p2tr: purpose = 86
        case .singleAddress:
            throw WalletKitError.internalError(message: "SingleAddress descriptors have no derivation path")
        }
        let coinType: UInt32 = network == .mainnet ? 0 : 1
        return try DerivationPath(string: "m/\(purpose)'/\(coinType)'/\(accountIndex)'")
    }

    /// Parses a `m/44'/60'/0'/0/0`-style derivation path string.
    ///
    /// - Parameter string: The path string to parse. Must start with `m`
    ///   and have at least one `/`-separated segment; each segment is a
    ///   non-negative integer optionally suffixed with `'`, `h`, or `H` to
    ///   mark it as hardened.
    /// - Throws: ``WalletKitError/invalidDerivationPath(path:)`` if
    ///   `string` doesn't match that shape.
    public init(string: String) throws {
        var parts = string.split(separator: "/", omittingEmptySubsequences: false).map(String.init)

        guard !parts.isEmpty, parts.removeFirst() == "m" else {
            throw WalletKitError.invalidDerivationPath(path: string)
        }

        var segments: [Segment] = []

        for part in parts {
            guard !part.isEmpty else {
                throw WalletKitError.invalidDerivationPath(path: string)
            }
            let hardened = part.hasSuffix("'") || part.hasSuffix("h") || part.hasSuffix("H")
            let digits = hardened ? String(part.dropLast()) : part
            guard let index = UInt32(digits) else {
                throw WalletKitError.invalidDerivationPath(path: string)
            }

            segments.append(Segment(index: index, hardened: hardened))
        }

        guard !segments.isEmpty else {
            throw WalletKitError.invalidDerivationPath(path: string)
        }

        self.init(segments: segments)
    }

    /// The `m/44'/60'/0'/0/0`-style string representation of this path.
    public var string: String {
        var result = "m"

        for segment in segments {
            result += "/\(segment.index)"
            if segment.hardened {
                result += "'"
            }
        }

        return result
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(segments, forKey: .segments)
    }

    private enum CodingKeys: CodingKey {
        case segments
    }
}
