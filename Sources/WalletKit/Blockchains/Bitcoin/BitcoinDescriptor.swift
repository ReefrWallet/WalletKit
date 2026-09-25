//
//  BitcoinDescriptor.swift
//  WalletKit
//

import Foundation
import WalletKitRust

/// A validated Bitcoin account identity.
///
/// A descriptor is `wpkh(...)` or `tr(...)` for a derivable account, or
/// `addr(...)` for a watch-only or transfer-destination address.
///
/// Doubles as the transaction builder's `recipient` address type: a plain
/// destination address string parses as a
/// `SingleAddress` descriptor (see ``init(string:)``), so `sender` and
/// `recipient` share one `Address` type without a second wrapper.
public struct BitcoinDescriptor: BlockchainAddress {
    /// The BIP-32 fingerprint for `publicKey` — the first 4 bytes of
    /// `RIPEMD160(SHA256(publicKey))`. Account creation computes this for
    /// a newly derived master key to build the ``BitcoinDescriptor`` for
    /// that account (see ``init(xpub:scriptType:network:masterFingerprint:accountPath:)``).
    ///
    /// - Throws: ``WalletKitError/invalidAddress(reason:)`` if `publicKey`
    ///   isn't secp256k1, or its raw bytes aren't a valid compressed
    ///   public key.
    public static func fingerprint(of publicKey: PublicKey) throws -> Data {
        guard publicKey.curve == .secp256k1 else {
            throw WalletKitError.unsupportedCurve(curve: publicKey.curve)
        }
        return try remappingWalletKitError { try bitcoinFingerprint(publicKey: publicKey.rawBytes) }
    }

    let raw: BitcoinDescriptorFfi

    init(raw: BitcoinDescriptorFfi) {
        self.raw = raw
    }

    /// This descriptor's canonical text encoding.
    ///
    /// The value is stable for the descriptor's lifetime.
    public var string: String {
        try! raw.string() // swiftlint:disable:this force_try
    }

    /// A descriptor has no fixed-width binary form the way a 20/32-byte
    /// hash-based address does (unlike ``EthereumAddress``/``SuiAddress``)
    /// — its UTF-8 text is already the canonical stable identity.
    public var rawBytes: Data {
        Data(string.utf8)
    }

    /// Parses `string` as one of WalletKit's descriptor shapes,
    /// inferring network from its xpub/tpub version prefix: `.mainnet`
    /// for an `xpub`-rooted descriptor, `.testnet` for anything else
    /// (`tpub`, or a plain address with no xpub at all).
    ///
    /// `tpub` doesn't distinguish testnet from signet/regtest, so this
    /// generic, network-less initializer — required by
    /// ``BlockchainAddress``, and the only one `AnyBlockchainClient`'s
    /// type-erasure bridging can call — can't tell those apart. Every
    /// internal call site (the address resolver, the transaction builder)
    /// knows its account's network already and calls
    /// ``init(string:network:)`` directly instead; this inferring
    /// initializer only fires for the generic bridging path, where sender
    /// and recipient always share one account's network in practice.
    ///
    /// - Throws: ``WalletKitError/invalidAddress(reason:)``.
    public init(string: String) throws {
        let inferredNetwork: BitcoinNetwork = string.contains("xpub") ? .mainnet : .testnet
        try self.init(string: string, network: inferredNetwork)
    }

    /// Parses `string` as one of WalletKit's descriptor shapes for
    /// `network` — use this whenever the account's actual network is
    /// known, rather than the network-less ``init(string:)``.
    ///
    /// - Throws: ``WalletKitError/invalidAddress(reason:)``.
    public init(string: String, network: BitcoinNetwork) throws {
        raw = try remappingWalletKitError { try BitcoinDescriptorFfi.fromString(string: string, network: network.raw) }
    }

    /// Builds a `wpkh(...)`/`tr(...)` descriptor from an account-level
    /// xpub and its BIP-32 origin.
    ///
    /// - Throws: ``WalletKitError/invalidAddress(reason:)``.
    public init(
        xpub: String,
        scriptType: BitcoinScriptType,
        network: BitcoinNetwork,
        masterFingerprint: Data,
        accountPath: String
    ) throws {
        raw = try remappingWalletKitError {
            try BitcoinDescriptorFfi.fromXpub(
                xpub: xpub,
                scriptType: scriptType.raw,
                network: network.raw,
                masterFingerprint: masterFingerprint,
                accountPath: accountPath
            )
        }
    }

    /// Wraps a single watch-only/destination address with no derivable
    /// keys behind it.
    ///
    /// - Throws: ``WalletKitError/invalidAddress(reason:)``.
    public init(address: String, network: BitcoinNetwork) throws {
        raw = try remappingWalletKitError { try BitcoinDescriptorFfi.fromAddress(address: address, network: network.raw) }
    }

    /// Wraps `rawBytes` (UTF-8 descriptor text) as a descriptor — the
    /// counterpart to ``rawBytes``.
    ///
    /// - Throws: ``WalletKitError/invalidAddress(reason:)`` if `rawBytes`
    ///   isn't valid UTF-8, or doesn't parse per ``init(string:)``.
    public init(rawBytes: Data) throws {
        guard let string = String(data: rawBytes, encoding: .utf8) else {
            throw WalletKitError.invalidAddress(reason: "Bitcoin descriptor bytes are not valid UTF-8")
        }
        try self.init(string: string)
    }

    public var scriptType: BitcoinScriptType { BitcoinScriptType(raw: raw.scriptType()) }

    public var network: BitcoinNetwork {
        switch raw.network() {
        case .mainnet: .mainnet
        case .testnet: .testnet
        case .signet: .signet
        case .regtest: .regtest
        }
    }

    public var masterFingerprint: Data { raw.masterFingerprint() }

    /// The account-level path this descriptor's xpub sits at (e.g.
    /// `"84'/0'/0'"`, no leading `m/`) — empty for `.singleAddress`.
    public var accountPath: String { raw.accountPath() }

    /// Derives the address at `chain` (`0` = external/receive, `1` =
    /// change) and `index` — always the wrapped single address for a
    /// `.singleAddress` descriptor, regardless of `chain`/`index`.
    ///
    /// - Throws: ``WalletKitError/invalidAddress(reason:)``.
    public func deriveAddress(chain: UInt32, index: UInt32) throws -> BitcoinAddressFfi {
        try remappingWalletKitError { try raw.deriveAddress(chain: chain, index: index) }
    }

    /// The 33-byte compressed secp256k1 public key at `chain`/`index`.
    ///
    /// - Throws: ``WalletKitError/keyNotFound`` for a `.singleAddress`
    ///   descriptor — there is no key behind a watch-only address.
    public func derivePublicKey(chain: UInt32, index: UInt32) throws -> Data {
        try remappingWalletKitError { try raw.derivePublicKey(chain: chain, index: index) }
    }

    public static func == (lhs: BitcoinDescriptor, rhs: BitcoinDescriptor) -> Bool {
        lhs.string == rhs.string
    }
}

/// Which script type a ``BitcoinDescriptor`` derives its own addresses as.
public enum BitcoinScriptType: Equatable, Hashable, Sendable {
    /// BIP-84 native SegWit (`bc1q…`).
    case p2wpkh
    /// BIP-86 Taproot (`bc1p…`).
    case p2tr
    /// A watch-only `addr(...)` descriptor — no derivable keys.
    case singleAddress

    init(raw: BitcoinScriptTypeFfi) {
        switch raw {
        case .p2wpkh: self = .p2wpkh
        case .p2tr: self = .p2tr
        case .singleAddress: self = .singleAddress
        }
    }

    var raw: BitcoinScriptTypeFfi {
        switch self {
        case .p2wpkh: .p2wpkh
        case .p2tr: .p2tr
        case .singleAddress: .singleAddress
        }
    }
}
