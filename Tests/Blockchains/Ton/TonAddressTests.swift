import Foundation
import Testing
@testable import WalletKit

struct TonAddressTests {
    /// The TON docs' example address in its bounceable and raw forms.
    private let friendly = "EQCD39VS5jcptHL8vMjEXrzGaRcCVYto7HUn4bpAOg8xqB2N"
    private let raw = "0:83dfd552e63729b472fcbcc8c45ebcc6691702558b68ec7527e1ba403a0f31a8"

    @Test func crc16MatchesTheXmodemCheckValue() {
        #expect(TonAddress.crc16(Array("123456789".utf8)) == 0x31C3)
    }

    @Test func friendlyAndRawFormsAgree() throws {
        let fromFriendly = try TonAddress(string: friendly)
        let fromRaw = try TonAddress(string: raw)
        #expect(fromFriendly == fromRaw)
        #expect(fromFriendly.isBounceable == true)
        #expect(fromRaw.isBounceable == nil)
        #expect(fromFriendly.rawString == raw)
        #expect(try fromFriendly.bounceable(true).string == friendly)
    }

    @Test func acceptsBothBase64Alphabets() throws {
        let standard = friendly.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        #expect(try TonAddress(string: standard) == TonAddress(string: friendly))
    }

    @Test func rejectsABadChecksum() {
        var corrupted = friendly
        corrupted.removeLast()
        corrupted.append("A")
        #expect(throws: WalletKitError.self) { try TonAddress(string: corrupted) }
    }

    @Test func rejectsTestnetOnlyAddressesOnMainnet() throws {
        let hash = Data(repeating: 7, count: 32)
        let testOnly = try TonAddress(workchain: 0, hash: hash, isBounceable: false, isTestOnly: true)
        let parsed = try TonAddress(string: testOnly.string)
        #expect(parsed.isTestOnly)
        #expect(throws: WalletKitError.self) { try parsed.validate(for: .mainnet) }
        #expect(throws: Never.self) { try parsed.validate(for: .testnet) }
    }

    @Test func v5r1AddressDiffersPerNetworkAndIsDeterministic() throws {
        let key = try Mnemonic.generate().toSeed().masterKey(curve: .ed25519).privateKey().publicKey
        let mainnet = try TonAddress(publicKey: key, network: .mainnet)
        let testnet = try TonAddress(publicKey: key, network: .testnet)
        #expect(mainnet != testnet)
        #expect(try mainnet == TonAddress(publicKey: key, network: .mainnet))
        #expect(mainnet.isBounceable == false)
        #expect(testnet.isTestOnly)
    }

    @Test func derivesAtTheTep3Path() throws {
        let path = try DerivationPath(.ton(.mainnet), accountIndex: 2, curve: .ed25519)
        #expect(path.string == "m/44'/607'/2'")
        #expect(throws: Never.self) { try path.validate(for: .ton(.mainnet), curve: .ed25519) }
    }
}
