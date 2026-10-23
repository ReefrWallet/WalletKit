// Spec-driven test for Docs/Design Specification/Core/DerivationPath.swift.
// Will compile once the corresponding type is exported from Sources.

import Testing
@testable import WalletKit
import WalletKitRust

struct DerivationPathTests {
    @Test func parsesStandardBip44String() throws {
        let path = try DerivationPath(string: "m/44'/60'/0'/0/0")
        #expect(path.segments.map(\.index) == [44, 60, 0, 0, 0])
        #expect(path.segments.map(\.hardened) == [true, true, true, false, false])
    }

    @Test func stringRoundTripsThroughParsing() throws {
        let original = "m/44'/60'/0'/0/0"
        let path = try DerivationPath(string: original)
        #expect(path.string == original)
    }

    @Test func invalidStringThrowsInvalidDerivationPath() {
        #expect(throws: WalletKitError.self) {
            _ = try DerivationPath(string: "not-a-path")
        }
    }

    @Test(arguments: [
        ("m/1852'/1815'/42'", Blockchain.cardano(.mainnet), nil as Curve?),
        ("m/44'/60'/0'/0/7", .evm(.ethereum(.mainnet)), nil),
        ("m/44'/501'/3'/0'", .solana(.mainnet), nil),
        ("m/44'/784'/0'/0'/1'", .sui(.mainnet), .ed25519)
    ])
    func validatesAccountPath(string: String, blockchain: Blockchain, curve: Curve?) throws {
        #expect(try DerivationPath(string: string, for: blockchain, curve: curve).string == string)
    }

    @Test(arguments: [
        ("m/123'/1815'/1'", Blockchain.cardano(.mainnet), nil as Curve?),
        ("m/1852/1815/1'", .cardano(.mainnet), nil),
        ("m/44'/784'/0/0/1", .sui(.mainnet), .ed25519),
        ("m/44'/60'/0'/0'/1'", .sui(.mainnet), .ed25519),
        ("m/44'/60'/0'/0'/1'", .evm(.ethereum(.mainnet)), nil),
        ("m/44'/501'/0'/0/0", .solana(.mainnet), nil)
    ])
    func rejectsMismatchedPath(string: String, blockchain: Blockchain, curve: Curve?) {
        #expect(throws: WalletKitError.self) {
            _ = try DerivationPath(string: string, for: blockchain, curve: curve)
        }
    }

    @Test func ordersByAccountThenChangeThenIndex() throws {
        let paths = try [
            "m/44'/60'/0'/0/10",
            "m/44'/60'/0'/1/0",
            "m/44'/60'/1'/0/0",
            "m/44'/60'/0'/0/2",
            "m/44'/501'/0'",
            "m/44'/501'/0'/0'"
        ].map { try DerivationPath(string: $0) }

        #expect(paths.sorted().map(\.string) == [
            "m/44'/60'/0'/0/2",
            "m/44'/60'/0'/0/10",
            "m/44'/60'/0'/1/0",
            "m/44'/60'/1'/0/0",
            "m/44'/501'/0'",
            "m/44'/501'/0'/0'"
        ])
    }

    @Test func ordersNonHardenedBeforeHardened() throws {
        let plain = try DerivationPath(string: "m/44'/60'/5")
        let hardened = try DerivationPath(string: "m/44'/60'/0'")
        #expect(plain < hardened)
    }

    @Test func validatesExistingPath() throws {
        let path = try DerivationPath.cardanoAccount(accountIndex: 3)
        try path.validate(for: .cardano(.mainnet))
        #expect(throws: WalletKitError.self) { try path.validate(for: .evm(.ethereum(.mainnet))) }
    }
}
