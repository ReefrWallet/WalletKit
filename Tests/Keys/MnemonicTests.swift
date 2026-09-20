// Spec-driven test for Docs/Design Specification/Keys/Mnemonic.swift.
// Will compile once the corresponding type is exported from Sources.

import Testing
@testable import WalletKit
import WalletKitRust

struct MnemonicTests {
    @Test func generateDefaultsTo24WordsAndEnglish() {
        let mnemonic = Mnemonic.generate()
        #expect(mnemonic.wordCount == .words24)
        #expect(mnemonic.wordlist == .english)
    }

    @Test(arguments: [MnemonicWordCount.words12, .words15, .words18, .words21, .words24])
    func generateHonorsRequestedWordCount(wordCount: MnemonicWordCount) {
        let mnemonic = Mnemonic.generate(wordCount: wordCount)
        #expect(mnemonic.wordCount == wordCount)
        #expect(mnemonic.phrase.split(separator: " ").count == Int(wordCount.rawValue))
    }

    @Test func fromPhraseValidatesTheBip39Checksum() {
        #expect(throws: WalletKitError.self) {
            _ = try Mnemonic.fromPhrase("not a valid bip39 phrase at all here")
        }
    }

    @Test func fromPhraseRoundTripsAGeneratedMnemonic() throws {
        let generated = Mnemonic.generate(wordCount: .words12)
        let restored = try Mnemonic.fromPhrase(generated.phrase)
        #expect(restored.phrase == generated.phrase)
    }

    @Test func toSeedIsDeterministicForTheSamePassphrase() {
        let mnemonic = Mnemonic.generate()
        let seedA = mnemonic.toSeed(passphrase: "correct horse")
        let seedB = mnemonic.toSeed(passphrase: "correct horse")
        #expect(seedA.exportRaw() == seedB.exportRaw())
    }

    @Test func toSeedDiffersForADifferentPassphrase() {
        let mnemonic = Mnemonic.generate()
        let withPassphrase = mnemonic.toSeed(passphrase: "correct horse")
        let withoutPassphrase = mnemonic.toSeed()
        #expect(withPassphrase.exportRaw() != withoutPassphrase.exportRaw())
    }
}
