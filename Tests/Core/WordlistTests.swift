// Spec-driven test for Docs/Design Specification/Core/Wordlist.swift.
// Will compile once the corresponding type is exported from Sources.

import Testing
@testable import WalletKit
import WalletKitRust

struct WordlistTests {
    @Test func allCasesIncludesEnglish() {
        #expect(Wordlist.allCases.contains(.english))
    }

    @Test(arguments: Wordlist.allCases)
    func wordsHas2048Entries(wordlist: Wordlist) {
        #expect(wordlist.words.count == 2048)
    }

    @Test func englishWordsStartsWithAbandonAndEndsWithZoo() {
        #expect(Wordlist.english.words.first == "abandon")
        #expect(Wordlist.english.words.last == "zoo")
    }

    @Test(arguments: Wordlist.allCases)
    func generatedPhraseWordsAreAllInWordlist(wordlist: Wordlist) {
        let mnemonic = Mnemonic.generate(wordlist: wordlist)
        let words = Set(wordlist.words)
        for word in mnemonic.phrase.split(separator: " ") {
            #expect(words.contains(String(word)))
        }
    }
}
