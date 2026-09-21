//
//  Mnemonic.swift
//  WalletKit
//
//  Created by Andrey Yurkevich on 16/08/2026.
//

@_exported import enum WalletKitRust.MnemonicWordCount
@_exported import enum WalletKitRust.Wordlist
import class WalletKitRust.MnemonicFfi

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
/// Backed by ``MnemonicFfi``, which holds the phrase in Rust-managed,
/// zeroized memory; the phrase is only copied into a Swift `String` (see
/// ``phrase``) when read explicitly.
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
    public static func generate(wordCount: MnemonicWordCount = .words24, wordlist: Wordlist = .english) -> Mnemonic {
        Mnemonic(raw: MnemonicFfi.generate(wordCount: wordCount, wordlist: wordlist))
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
            Mnemonic(raw: try MnemonicFfi.fromPhrase(phrase: phrase, wordlist: wordlist))
        }
    }

    /// The space-separated recovery phrase, e.g. `"abandon abandon ... art"`.
    ///
    /// - Warning: This is as sensitive as the wallet's private keys —
    ///   anyone with the phrase can recreate every account derived from it.
    ///   Treat it as short-lived and never log or persist it in plaintext.
    public var phrase: String { raw.phrase() }

    /// The number of words in ``phrase`` (12, 15, 18, 21, or 24).
    public var wordCount: MnemonicWordCount { raw.wordCount() }

    /// The BIP39 wordlist ``phrase``'s words were drawn from.
    public var wordlist: Wordlist { raw.wordlist() }

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

#if SWIFT_PACKAGE
extension MnemonicWordCount: RawRepresentable {
    public typealias RawValue = UInt32

    /// The number of words this case represents (12, 15, 18, 21, or 24).
    public var rawValue: UInt32 {
        switch self {
        case .words12: return 12
        case .words15: return 15
        case .words18: return 18
        case .words21: return 21
        case .words24: return 24
        }
    }

    /// Creates a word count from its raw integer value.
    ///
    /// - Parameter rawValue: A BIP39 word count (12, 15, 18, 21, or 24).
    /// - Returns: `nil` if `rawValue` isn't a supported BIP39 word count.
    public init?(rawValue: UInt32) {
        switch rawValue {
        case 12: self = .words12
        case 15: self = .words15
        case 18: self = .words18
        case 21: self = .words21
        case 24: self = .words24
        default: return nil
        }
    }
}
#else
extension MnemonicWordCount: @retroactive RawRepresentable {
    public typealias RawValue = UInt32

    /// The number of words this case represents (12, 15, 18, 21, or 24).
    public var rawValue: UInt32 {
        switch self {
        case .words12: return 12
        case .words15: return 15
        case .words18: return 18
        case .words21: return 21
        case .words24: return 24
        }
    }

    /// Creates a word count from its raw integer value.
    ///
    /// - Parameter rawValue: A BIP39 word count (12, 15, 18, 21, or 24).
    /// - Returns: `nil` if `rawValue` isn't a supported BIP39 word count.
    public init?(rawValue: UInt32) {
        switch rawValue {
        case 12: self = .words12
        case 15: self = .words15
        case 18: self = .words18
        case 21: self = .words21
        case 24: self = .words24
        default: return nil
        }
    }
}
#endif
