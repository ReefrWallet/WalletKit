// Spec-driven test for Docs/Design Specification/Clients/Signer.swift.
//
// Ethereum's real conformers are covered separately by
// EthereumPKeySignerTests/EthereumTrezorSignerTests and EthereumAddressTests;
// this exercises the protocol's shape itself through a local mock,
// independent of any one chain.

import Foundation
import Testing
@testable import WalletKit
import WalletKitRust

private struct MockAddress: BlockchainAddress {
    let string: String

    init(string: String) throws {
        self.string = string
    }

    init(rawBytes: Data) throws {
        guard let string = String(bytes: rawBytes, encoding: .utf8)  else {
            throw WalletKitError.invalidAddress(reason: "Invalid bytes")
        }

        self.string = string
    }

    var rawBytes: Data { Data(string.utf8) }
}

private struct MockSigner: Signer {
    typealias Address = MockAddress

    let account: WKAccount
    let addressString: String
    let signHandler: (Data) async throws -> Data

    func address() throws -> MockAddress {
        try MockAddress(string: addressString)
    }

    func sign(transaction: Data) async throws -> Data {
        try await signHandler(transaction)
    }
}

struct SignerTests {
    @Test func addressReflectsTheSignersConfiguredValue() throws {
        let account = try TestAccountFactory.ethereumAccount()
        let signer = MockSigner(account: account, addressString: "0xmocked", signHandler: { data in data })
        let address = try signer.address()
        #expect(address.string == "0xmocked")
    }

    @Test func blockchainDefaultsToTheAccountsBlockchain() throws {
        let account1 = try TestAccountFactory.bitcoinAccount(network: .mainnet)
        let signer1 = MockSigner(account: account1, addressString: "", signHandler: { data in data })
        #expect(signer1.blockchain == .bitcoin(.mainnet))

        let account2 = try TestAccountFactory.bitcoinAccount(network: .testnet)
        let signer2 = MockSigner(account: account2, addressString: "", signHandler: { data in data })
        #expect(signer2.blockchain == .bitcoin(.testnet))
    }

    @Test func signForwardsTheTransaction() async throws {
        let account = try TestAccountFactory.ethereumAccount()
        var receivedTransaction: Data?
        let signer = MockSigner(
            account: account,
            addressString: "",
            signHandler: { data in
                receivedTransaction = data
                return data
            }
        )

        let transaction = Data([0x01, 0x02, 0x03])
        let signed = try await signer.sign(transaction: transaction)
        #expect(signed == transaction)
        #expect(receivedTransaction == transaction)
    }
}
