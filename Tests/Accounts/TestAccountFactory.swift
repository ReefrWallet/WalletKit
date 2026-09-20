// Shared test helper for constructing `Account`s directly.
//
// Normally an `Account` only exists bound to a `Signer` (software) or a
// `HardwareDevice` (hardware) — `WKBlockchain` carries no curve/
// derivation-path logic of its own, and picking the right ones for a
// chain is that conformer's job. Tests that need a bare `Account` without
// a signer attached build one directly here, via `Account`'s internal
// initializer (visible through `@testable import`) plus a freshly
// generated key.

import Foundation
@testable import WalletKit
import WalletKitRust

enum TestAccountFactory {
    /// Builds a software-sourced `Account` for `blockchain`, deriving a
    /// fresh key with `curve` at `derivationPath`.
    static func makeAccount(
        blockchain: WKBlockchain,
        curve: Curve,
        derivationPath: DerivationPath
    ) throws -> WKAccount {
        let seed = Mnemonic.generate().toSeed()
        let key = try seed.masterKey(curve: curve).derive(derivationPath)
        return WKAccount(
            blockchain: blockchain,
            derivationPath: derivationPath,
            curve: curve,
            source: .software,
            publicKey: key.publicKey
        )
    }

    /// The standard `m/44'/coinType'/account'/0/0` path for secp256k1-based
    /// chains (Bitcoin, Ethereum, Tron), which mix hardened/non-hardened
    /// segments per BIP44.
    static func bip44Path(
        coinType: UInt32,
        account: UInt32 = 0
    ) -> DerivationPath {
        DerivationPath(segments: [
            Segment(index: 44, hardened: true),
            Segment(index: coinType, hardened: true),
            Segment(index: account, hardened: true),
            Segment(index: 0, hardened: false),
            Segment(index: 0, hardened: false)
        ])
    }

    /// The fully-hardened `m/44'/coinType'/account'/0'/0'` path for
    /// ed25519-based chains (Solana, Cardano, Sui) — SLIP-0010 only
    /// supports hardened derivation.
    static func slip10Path(coinType: UInt32, account: UInt32 = 0) -> DerivationPath {
        DerivationPath(segments: [
            Segment(index: 44, hardened: true),
            Segment(index: coinType, hardened: true),
            Segment(index: account, hardened: true),
            Segment(index: 0, hardened: true),
            Segment(index: 0, hardened: true)
        ])
    }

    static func ethereumAccount(chainId: UInt64 = 1, account: UInt32 = 0) throws -> WKAccount {
        try makeAccount(
            blockchain: .evm(EVMBlockchain(chainId: chainId)),
            curve: .secp256k1,
            derivationPath: bip44Path(coinType: 60, account: account)
        )
    }

    static func bitcoinAccount(network: BitcoinNetwork, account: UInt32 = 0) throws -> WKAccount {
        try makeAccount(
            blockchain: .bitcoin(network),
            curve: .secp256k1,
            derivationPath: bip44Path(coinType: 0, account: account)
        )
    }

    static func solanaAccount(network: SolanaNetwork, account: UInt32 = 0) throws -> WKAccount {
        try makeAccount(
            blockchain: .solana(network),
            curve: .ed25519,
            derivationPath: slip10Path(coinType: 501, account: account)
        )
    }

    static func suiAccount(network: SuiNetwork, curve: Curve = .ed25519, account: UInt32 = 0) throws -> WKAccount {
        try makeAccount(
            blockchain: .sui(network),
            curve: curve,
            derivationPath: slip10Path(coinType: 784, account: account)
        )
    }
}
