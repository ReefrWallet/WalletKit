//
//  Wordlist.swift
//  WalletKit
//
//  Created by Andrey Yurkevich on 16/08/2026.
//

import func WalletKitRust.wordlistWords

public extension Wordlist {
    init?(storageIdentifier: String) {
        switch storageIdentifier {
        case "chineseSimplified": self = .chineseSimplified
        case "chineseTraditional": self = .chineseTraditional
        case "czech": self = .czech
        case "english": self = .english
        case "french": self = .french
        case "italian": self = .italian
        case "japanese": self = .japanese
        case "korean": self = .korean
        case "portuguese": self = .portuguese
        case "spanish": self = .spanish
        default: return nil
        }
    }

    var storageIdentifier: String {
        switch self {
        case .chineseSimplified: "chineseSimplified"
        case .chineseTraditional: "chineseTraditional"
        case .czech: "czech"
        case .english: "english"
        case .french: "french"
        case .italian: "italian"
        case .japanese: "japanese"
        case .korean: "korean"
        case .portuguese: "portuguese"
        case .spanish: "spanish"
        }
    }

    /// The 2048 words this wordlist draws from, in BIP39 index order.
    var words: [String] { wordlistWords(wordlist: self) }
}
