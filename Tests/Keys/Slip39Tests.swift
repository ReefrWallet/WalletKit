// SLIP-39 against the official vectors (TestVectors/slip39.json: the Trezor
// vector set, passphrase "TREZOR"). The expected BIP-32 master keys in that
// file were computed independently of WalletKit.

import Foundation
import Testing
@testable import WalletKit

private struct Slip39Vector: Sendable, CustomTestStringConvertible {
    let mnemonics: [String]
    let masterSecret: String
    let xprv: String?

    var testDescription: String { mnemonics.first.map { String($0.prefix(40)) } ?? "empty" }
}

private struct Slip39VectorFile: Decodable {
    struct Entry: Decodable {
        let mnemonics: [String]
        let masterSecret: String
        let bip32Xprv: String?
    }

    let passphrase: String
    let vectors: [Entry]
}

private let file: Slip39VectorFile = {
    let url = Bundle.module.url(forResource: "slip39", withExtension: "json")!
    // swiftlint:disable:next force_try
    return try! JSONDecoder().decode(Slip39VectorFile.self, from: Data(contentsOf: url))
}()

private let vectors = file.vectors.map {
    Slip39Vector(mnemonics: $0.mnemonics, masterSecret: $0.masterSecret, xprv: $0.bip32Xprv)
}

private extension Data {
    var hex: String { map { String(format: "%02x", $0) }.joined() }
}

struct Slip39Tests {
    @Test(arguments: vectors)
    fileprivate func officialVector(vector: Slip39Vector) async throws {
        let shares = try? vector.mnemonics.map(Slip39.decodeShare)
        let encrypted = shares.flatMap { try? Slip39.recoverEncryptedSecret($0) }
        let secret: Data? = try? await encrypted?.decrypt(passphrase: file.passphrase)

        if vector.masterSecret.isEmpty {
            #expect(secret == nil)
            return
        }

        let recovered = try #require(secret)
        #expect(recovered.hex == vector.masterSecret)

        let master = try Seed(masterSecret: recovered).masterKey(curve: .secp256k1)
        #expect(try master.serializedPrivate() == vector.xprv)
    }

    @Test func wordlistHas1024SortedWords() {
        #expect(Slip39.words.count == 1024)
        #expect(Slip39.words == Slip39.words.sorted())
    }

    @Test func passphraseIsUsedExactly() async throws {
        let valid = try #require(file.vectors.first { !$0.masterSecret.isEmpty })
        let shares = try valid.mnemonics.map(Slip39.decodeShare)
        let encrypted = try Slip39.recoverEncryptedSecret(shares)

        let base = try await encrypted.decrypt(passphrase: file.passphrase)
        #expect(try await encrypted.decrypt(passphrase: file.passphrase.lowercased()) != base)
        #expect(try await encrypted.decrypt(passphrase: " " + file.passphrase) != base)
        #expect(try await encrypted.decrypt(passphrase: file.passphrase + " ") != base)
        #expect(try await encrypted.decrypt(passphrase: "") != base)
    }

    @Test func nonASCIIPassphraseIsRejected() async throws {
        let valid = try #require(file.vectors.first { !$0.masterSecret.isEmpty })
        let encrypted = try Slip39.recoverEncryptedSecret(valid.mnemonics.map(Slip39.decodeShare))

        await #expect(throws: Slip39Error.invalidPassphrase) {
            _ = try await encrypted.decrypt(passphrase: "pässword")
        }
    }

    @Test func cancelledTaskThrowsCancelled() async throws {
        let valid = try #require(file.vectors.first { !$0.masterSecret.isEmpty })
        let encrypted = try Slip39.recoverEncryptedSecret(valid.mnemonics.map(Slip39.decodeShare))

        let task = Task { try await encrypted.decrypt(passphrase: "") }
        task.cancel()

        // Either the cancel won the race and surfaced, or decryption finished first.
        do {
            _ = try await task.value
        } catch {
            #expect(error as? Slip39Error == .cancelled)
        }
    }

    @Test(arguments: [(Slip39Strength.bits128, 20), (Slip39Strength.bits256, 33)])
    func generatedSingleShareRestoresItsMasterSecret(strength: Slip39Strength, words: Int) async throws {
        let generated = try Slip39.generateSingleShare(strength: strength)
        let share = try Slip39.decodeShare(generated.mnemonic)

        #expect(share.wordCount == words)
        #expect(generated.masterSecret.count == Int(strength.rawValue) / 8)

        var set = Slip39ShareSet()
        try set.add(share)
        #expect(set.isComplete)

        let restored = try await set.encryptedSecret().decrypt(passphrase: "")
        #expect(restored == generated.masterSecret)
    }

    @Test func unsupportedLengthIsRejected() {
        let words = Array(repeating: "academic", count: 59).joined(separator: " ")
        #expect(throws: Slip39Error.unsupportedLength(count: 59)) {
            _ = try Slip39.decodeShare(words)
        }
    }

    @Test func unknownWordIsRejected() {
        #expect(throws: Slip39Error.unknownWord("notaword")) {
            _ = try Slip39.decodeShare("notaword academic")
        }
    }
}

// MARK: - Share set

struct Slip39ShareSetTests {
    /// A 2-of-3 backup (single group) and a 2-group backup from the vectors.
    private static func shares(containing count: Int, groups: Int? = nil) throws -> [Slip39Share] {
        let candidates = try file.vectors.filter { !$0.masterSecret.isEmpty && $0.mnemonics.count == count }
        let decoded = try candidates.map { try $0.mnemonics.map(Slip39.decodeShare) }
        return try #require(decoded.first { groups == nil || Set($0.map(\.groupIndex)).count == groups })
    }

    @Test func singleShareBackupIsCompleteAfterOneShare() throws {
        let single = try #require(
            file.vectors.first { !$0.masterSecret.isEmpty && $0.mnemonics.count == 1 }
        )

        let share = try Slip39.decodeShare(single.mnemonics[0])
        var set = Slip39ShareSet()
        #expect(!set.isComplete)

        try set.add(share)
        #expect(set.isComplete)
        #expect(set.sharesToCombine == [share])
        _ = try set.encryptedSecret()
    }

    @Test func completeSetCombinesAndRemovingAShareReopensIt() async throws {
        let all = try Self.shares(containing: 3)
        var set = Slip39ShareSet()

        for share in all {
            #expect(!set.isComplete)
            try set.add(share)
        }

        #expect(set.isComplete)
        #expect(set.sharesToCombine.count == all.count)
        _ = try set.encryptedSecret()

        set.remove(all[0])
        #expect(!set.isComplete)
        #expect(set.sharesToCombine.isEmpty)
        #expect(throws: Slip39Error.self) { _ = try set.encryptedSecret() }

        set.removeAll()
        #expect(set.isEmpty)
    }

    @Test func duplicateAndConflictingSharesAreRejected() throws {
        let all = try Self.shares(containing: 3)
        var set = Slip39ShareSet()
        try set.add(all[0])
        #expect(throws: Slip39Error.duplicateShare) { try set.add(all[0]) }
    }

    @Test func shareFromAnotherBackupIsRejected() throws {
        let first = try Self.shares(containing: 3)
        let other = try #require(
            file.vectors.first { !$0.masterSecret.isEmpty && $0.mnemonics.count == 1 }
        )

        var set = Slip39ShareSet()
        try set.add(first[0])

        #expect(throws: Slip39Error.self) { try set.add(Slip39.decodeShare(other.mnemonics[0])) }
    }
}

// MARK: - Seeds and Cardano

struct MasterSecretTests {
    @Test(arguments: [16, 20, 32, 64])
    func acceptsValidLengths(length: Int) throws {
        let seed = try Seed(masterSecret: Data(repeating: 7, count: length))
        #expect(seed.exportRaw().count == length)
        _ = try seed.masterKey(curve: .ed25519)
    }

    @Test(arguments: [0, 15, 17, 65, 66])
    func rejectsInvalidLengths(length: Int) {
        #expect(throws: WalletKitError.self) {
            _ = try Seed(masterSecret: Data(repeating: 7, count: length))
        }
    }

    @Test func bip39SeedContractStaysSixtyFourBytes() {
        #expect(throws: WalletKitError.self) {
            _ = try Seed(rawBytes: Data(repeating: 7, count: 32))
        }
    }

    @Test func cardanoRootKindsDeriveDifferentAccounts() throws {
        let secret = Data(repeating: 9, count: 16)
        let path = try DerivationPath.cardanoAccount(accountIndex: 0)
        let bip39 = try CardanoAccountDescriptor(root: .bip39Entropy(secret), network: .preprod, path: path)
        let slip39 = try CardanoAccountDescriptor(root: .slip39MasterSecret(secret), network: .preprod, path: path)
        #expect(bip39.string != slip39.string)
        #expect(try CardanoAccountDescriptor(entropy: secret, network: .preprod, path: path).string == bip39.string)
    }
}
