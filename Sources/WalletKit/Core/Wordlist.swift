//
//  Wordlist.swift
//  WalletKit
//
//  Created by Andrey Yurkevich on 16/08/2026.
//

import enum WalletKitRust.WordlistFfi
import func WalletKitRust.wordlistWords

/// A BIP39 wordlist supported by WalletKit.
public enum Wordlist: String, CaseIterable, Codable, Sendable {
    case chineseSimplified
    case chineseTraditional
    case czech
    case english
    case french
    case italian
    case japanese
    case korean
    case portuguese
    case spanish

    init(raw: WordlistFfi) {
        switch raw {
        case .chineseSimplified:
            self = .chineseSimplified
        case .chineseTraditional:
            self = .chineseTraditional
        case .czech:
            self = .czech
        case .english:
            self = .english
        case .french:
            self = .french
        case .italian:
            self = .italian
        case .japanese:
            self = .japanese
        case .korean:
            self = .korean
        case .portuguese:
            self = .portuguese
        case .spanish:
            self = .spanish
        }
    }

    var raw: WordlistFfi {
        switch self {
        case .chineseSimplified: .chineseSimplified
        case .chineseTraditional: .chineseTraditional
        case .czech: .czech
        case .english: .english
        case .french: .french
        case .italian: .italian
        case .japanese: .japanese
        case .korean: .korean
        case .portuguese: .portuguese
        case .spanish: .spanish
        }
    }
}

public extension Wordlist {
    init?(storageIdentifier: String) {
        self.init(rawValue: storageIdentifier)
    }

    var storageIdentifier: String { rawValue }

    /// The 2048 words this wordlist draws from, in BIP39 index order.
    var words: [String] { wordlistWords(wordlist: raw) }
}
