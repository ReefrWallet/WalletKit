// Integration test for Mnemonic/Seed/ExtendedKey against the official BIP39
// test vectors (TestVectors/bip39.json, the standard Trezor python-mnemonic
// vectors, which use "TREZOR" as the passphrase when deriving each vector's
// seed). Moved out of the now-removed Wallet/ tests — Wallet itself is gone
// (see Docs/Design Specification/Core/Account.swift's doc comment), but this
// coverage never actually depended on it.

import Foundation
import Testing
@testable import WalletKit

private struct Bip39Vector: Sendable, CustomTestStringConvertible {
    let mnemonic: String
    let seedHex: String
    let xprv: String

    var testDescription: String { mnemonic }
}

private struct Bip39VectorFile: Decodable {
    let english: [[String]]
}

private func loadEnglishBip39Vectors() -> [Bip39Vector] {
    let url = Bundle.module.url(forResource: "bip39", withExtension: "json")!
    // swiftlint:disable force_try
    let data = try! Data(contentsOf: url)
    let file = try! JSONDecoder().decode(Bip39VectorFile.self, from: data)
    // swiftlint:enable force_try
    return file.english.map { row in
        Bip39Vector(mnemonic: row[1], seedHex: row[2], xprv: row[3])
    }
}

private extension String {
    /// Decodes a lowercase hex string, as used throughout the BIP39 vectors file.
    var hexDecoded: Data {
        var data = Data(capacity: count / 2)
        var index = startIndex
        while index < endIndex {
            let next = self.index(index, offsetBy: 2)
            data.append(UInt8(self[index..<next], radix: 16)!)
            index = next
        }
        return data
    }
}

private extension Data {
    var hexEncoded: String {
        map { String(format: "%02x", $0) }.joined()
    }
}

private let vectorPassphrase = "TREZOR"

struct Bip39VectorsTests {
    fileprivate static let vectors = loadEnglishBip39Vectors()

    @Test(arguments: vectors)
    fileprivate func restoredMnemonicReproducesTheOfficialSeedAndMasterKey(vector: Bip39Vector) throws {
        let mnemonic = try Mnemonic.fromPhrase(vector.mnemonic)
        #expect(mnemonic.phrase == vector.mnemonic)
        #expect(mnemonic.wordlist == .english)

        let seed = mnemonic.toSeed(passphrase: vectorPassphrase)
        #expect(seed.exportRaw().hexEncoded == vector.seedHex)

        let master = try seed.masterKey(curve: .secp256k1)
        #expect(try master.serializedPrivate() == vector.xprv)
    }

    @Test func restoringAKnownPhraseWithATamperedWordThrows() {
        let tampered = "zoo zoo zoo zoo zoo zoo zoo zoo zoo zoo zoo zoo"
        #expect(throws: WalletKitError.self) {
            _ = try Mnemonic.fromPhrase(tampered)
        }
    }
}
