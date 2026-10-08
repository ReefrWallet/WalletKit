//
//  Mnemonic.swift
//  WalletKit
//
//  Created by Andrey Yurkevich on 16/08/2026.
//

import WalletKitRust

/// A BIP39 recovery phrase, and the entry point for deriving the wallet's
/// seed from it.
///
/// Conform to this protocol (rather than depending on ``Mnemonic``
/// directly) when you need to mock mnemonic generation/import in tests.
public protocol MnemonicProtocol: AnyObject {
    /// The space-separated recovery phrase, e.g. `"abandon abandon ... art"`.
    ///
    /// - Warning: This is as sensitive as the wallet's private keys —
    ///   anyone with the phrase can recreate every account derived from it.
    ///   Treat it as short-lived and never log or persist it in plaintext.
    var phrase: String { get }

    /// The number of words in ``phrase`` (12, 15, 18, 21, or 24).
    var wordCount: MnemonicWordCount { get }

    /// The BIP39 wordlist ``phrase``'s words were drawn from.
    var wordlist: Wordlist { get }

    /// Derives the 64-byte BIP39 seed for this mnemonic.
    ///
    /// - Parameter passphrase: The optional BIP39 "25th word". Different
    ///   passphrases (including the default empty string) derive entirely
    ///   different, unrelated seeds from the same phrase.
    /// - Returns: The derived ``Seed``, ready for master-key derivation.
    func toSeed(passphrase: String) -> Seed
}

/// A BIP39 mnemonic recovery phrase.
///
/// Read ``phrase`` only when necessary, and treat the returned string as
/// sensitive wallet material.
public final class Mnemonic: MnemonicProtocol {
    let raw: MnemonicFfi

    init(raw: MnemonicFfi) {
        self.raw = raw
    }

    /// Generates a brand-new mnemonic from freshly-generated entropy.
    ///
    /// - Parameters:
    ///   - wordCount: The number of words the generated phrase should have.
    ///     Defaults to `.words24` (the maximum entropy BIP39 supports).
    ///   - wordlist: The wordlist to draw words from. Defaults to
    ///     `.english`.
    /// - Returns: A new ``Mnemonic`` wrapping the generated phrase.
    public static func generate(wordCount: MnemonicWordCount = .`12`, wordlist: Wordlist = .english) -> Mnemonic {
        Mnemonic(raw: MnemonicFfi.generate(wordCount: wordCount.raw, wordlist: wordlist.raw))
    }

    /// Imports a mnemonic from an existing recovery phrase.
    ///
    /// - Parameters:
    ///   - phrase: The space-separated recovery phrase to import.
    ///   - wordlist: The wordlist `phrase`'s words are drawn from. Defaults
    ///     to `.english`.
    /// - Returns: A ``Mnemonic`` wrapping the parsed phrase.
    /// - Throws: ``WalletKitError/invalidMnemonic(reason:)`` if `phrase`
    ///   isn't a well-formed phrase in `wordlist`, or fails the BIP39
    ///   checksum.
    public static func fromPhrase(_ phrase: String, wordlist: Wordlist = .english) throws -> Mnemonic {
        try remappingWalletKitError {
            Mnemonic(raw: try MnemonicFfi.fromPhrase(phrase: phrase, wordlist: wordlist.raw))
        }
    }

    /// Reconstructs a mnemonic from the original BIP-39 entropy.
    public static func fromEntropy(_ entropy: Data, wordlist: Wordlist = .english) throws -> Mnemonic {
        try remappingWalletKitError {
            Mnemonic(raw: try MnemonicFfi.fromEntropy(entropy: entropy, wordlist: wordlist.raw))
        }
    }

    /// The space-separated recovery phrase, e.g. `"abandon abandon ... art"`.
    ///
    /// - Warning: This is as sensitive as the wallet's private keys —
    ///   anyone with the phrase can recreate every account derived from it.
    ///   Treat it as short-lived and never log or persist it in plaintext.
    public var phrase: String { raw.phrase() }

    /// The number of words in ``phrase`` (12, 15, 18, 21, or 24).
    public var wordCount: MnemonicWordCount { MnemonicWordCount(raw: raw.wordCount()) }

    /// The BIP39 wordlist ``phrase``'s words were drawn from.
    public var wordlist: Wordlist { Wordlist(raw: raw.wordlist()) }

    /// The original BIP-39 entropy used for Cardano's Icarus derivation.
    public var entropy: Data { raw.entropy() }

    /// Derives the 64-byte BIP39 seed for this mnemonic.
    ///
    /// - Parameter passphrase: The optional BIP39 "25th word". Different
    ///   passphrases (including the default empty string) derive entirely
    ///   different, unrelated seeds from the same phrase.
    /// - Returns: The derived ``Seed``, ready for master-key derivation.
    public func toSeed(passphrase: String = "") -> Seed {
        Seed(raw: raw.toSeed(passphrase: passphrase))
    }
}

// MARK: - MnemonicWordCount

/// A supported BIP39 mnemonic word count.
public enum MnemonicWordCount: UInt32, CaseIterable, Codable, Sendable {
    // swiftlint:disable identifier_name
    case `12` = 12
    case `15` = 15
    case `18` = 18
    case `21` = 21
    case `24` = 24
    // swiftlint:enable identifier_name

    init(raw: MnemonicWordCountFfi) {
        switch raw {
        case .words12:
            self = .`12`
        case .words15:
            self = .`15`
        case .words18:
            self = .`18`
        case .words21:
            self = .`21`
        case .words24:
            self = .`24`
        }
    }

    var raw: MnemonicWordCountFfi {
        switch self {
        case .`12`: .words12
        case .`15`: .words15
        case .`18`: .words18
        case .`21`: .words21
        case .`24`: .words24
        }
    }
}
