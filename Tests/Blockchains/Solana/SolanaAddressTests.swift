import Foundation
import Testing
@testable import WalletKit

struct SolanaAddressTests {
    /// The System Program's address — the canonical all-zero-bytes vector,
    /// independently verifiable against any Solana explorer.
    private let systemProgramAddress = "11111111111111111111111111111111"

    @Test func base58VectorRoundTrips() throws {
        let address = try SolanaAddress(string: systemProgramAddress)
        #expect(address.rawBytes == Data(repeating: 0, count: 32))
        #expect(address.string == systemProgramAddress)
    }

    @Test func rejectsNonBase58Characters() {
        #expect(throws: WalletKitError.self) {
            _ = try SolanaAddress(string: String(repeating: "0", count: 32))
        }
    }

    @Test func rejectsTheWrongDecodedLength() {
        #expect(throws: WalletKitError.self) {
            _ = try SolanaAddress(string: "abc")
        }
    }

    @Test func rejectsTheWrongByteCount() {
        #expect(throws: WalletKitError.self) {
            _ = try SolanaAddress(rawBytes: Data(repeating: 0, count: 31))
        }
    }

    @Test func derivesFromAnEd25519PublicKeyWithNoHashing() throws {
        let seed = Mnemonic.generate().toSeed()
        let privateKey = try seed.masterKey(curve: .ed25519).privateKey()
        let address = try SolanaAddress(publicKey: privateKey.publicKey)
        // Solana addresses are the raw public key bytes, Base58-encoded —
        // unlike Sui, there is no hash step to independently verify here
        // beyond a direct byte comparison.
        #expect(address.rawBytes == privateKey.publicKey.rawBytes)
    }

    @Test func rejectsASecp256k1PublicKey() throws {
        let seed = Mnemonic.generate().toSeed()
        let privateKey = try seed.masterKey(curve: .secp256k1).privateKey()
        #expect(throws: WalletKitError.self) {
            _ = try SolanaAddress(publicKey: privateKey.publicKey)
        }
    }

    @Test func systemProgramAddressIsOnCurve() throws {
        // All-zero bytes decompress to the ed25519 identity element, which
        // libsodium/curve25519-dalek both treat as a valid curve point —
        // confirms `isOnCurve` isn't accidentally always false.
        let address = try SolanaAddress(string: systemProgramAddress)
        #expect(address.isOnCurve)
    }

    @Test func aFreshlyDerivedProgramAddressIsOffCurve() throws {
        // `solana_find_program_address`'s whole contract is landing on an
        // off-curve bump — this exercises that guarantee end to end
        // through `SolanaProgram`'s Swift-facing wrapper.
        let owner = try SolanaAddress(rawBytes: Data((0..<32).map(UInt8.init)))
        let mint = try SolanaAddress(rawBytes: Data((32..<64).map { UInt8($0 % 256) }))
        let ata = try SolanaProgram.associatedTokenAddress(owner: owner, mint: mint)
        #expect(!ata.isOnCurve)
    }

    @Test func equalityComparesRawBytes() throws {
        let first = try SolanaAddress(string: systemProgramAddress)
        let second = try SolanaAddress(rawBytes: Data(repeating: 0, count: 32))
        #expect(first == second)
    }
}
