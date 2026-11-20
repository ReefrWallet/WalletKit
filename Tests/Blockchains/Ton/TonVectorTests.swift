// Runs the shared `TestVectors/ton-*.json` files (generated with `@ton/ton` 16.3.0, `@ton/core` 0.63.1 and
// `@ton/crypto` 3.3.0 by `Scripts/ton-test-vectors/gen.mjs`) through the Swift API.

import BigInt
import Foundation
import Testing
@testable import WalletKit

private struct AddressVector: Decodable, Sendable, CustomTestStringConvertible {
    let label: String
    let network: String
    let privateKey: String
    let publicKey: String
    let address: String
    let raw: String
    let stateInitHash: String
    let codeHash: String
    let dataHash: String

    var testDescription: String { label }
}

private struct DerivationVector: Decodable, Sendable, CustomTestStringConvertible {
    let mnemonic: String
    let path: String
    let accountIndex: UInt64
    let network: String
    let privateKey: String
    let publicKey: String
    let address: String

    var testDescription: String { "\(path) \(network)" }
}

private struct TransferVector: Decodable, Sendable, CustomTestStringConvertible {
    let label: String
    let network: String
    let privateKey: String
    let sender: String
    let recipient: String
    let amount: String
    let comment: String?
    let seqno: UInt32
    let validUntil: UInt32
    let deploy: Bool
    let signingBodyHash: String
    let signature: String
    let signedBodyBocHex: String
    let externalMessageBocHex: String
    let normalizedHash: String

    var testDescription: String { label }
}

private func loadVectors<T: Decodable>(_ resource: String) -> [T] {
    // swiftlint:disable force_try
    let url = Bundle.module.url(forResource: resource, withExtension: "json")!
    return try! JSONDecoder().decode([T].self, from: Data(contentsOf: url))
    // swiftlint:enable force_try
}

private func network(_ name: String) -> TonNetwork {
    name == "mainnet" ? .mainnet : .testnet
}

private func hex(_ data: Data) -> String {
    data.map { String(format: "%02x", $0) }.joined()
}

struct TonVectorTests {
    @Test(arguments: loadVectors("ton-address") as [AddressVector])
    fileprivate func addressMatchesSdk(_ vector: AddressVector) throws {
        let key = try PrivateKey(curve: .ed25519, rawBytes: Data(hexString: vector.privateKey))
        #expect(hex(key.publicKey.rawBytes) == vector.publicKey)

        let address = try TonAddress(publicKey: key.publicKey, network: network(vector.network))
        #expect(address.string == vector.address)
        #expect(address.rawString == vector.raw)

        let stateInit = TonWalletV5R1.stateInit(publicKey: key.publicKey.rawBytes, network: network(vector.network))
        #expect(hex(stateInit.hash) == vector.stateInitHash)
        #expect(hex(stateInit.refs[0].hash) == vector.codeHash)
        #expect(hex(stateInit.refs[1].hash) == vector.dataHash)
    }

    @Test(arguments: loadVectors("ton-derivation") as [DerivationVector])
    fileprivate func derivedAddressMatchesSdk(_ vector: DerivationVector) throws {
        let path = try DerivationPath(.ton(.mainnet), accountIndex: vector.accountIndex, curve: .ed25519)
        #expect(path.string == vector.path)

        let key = try Mnemonic.fromPhrase(vector.mnemonic).toSeed().masterKey(curve: .ed25519).derive(path)
        let privateKey = try key.privateKey()
        #expect(hex(privateKey.publicKey.rawBytes) == vector.publicKey)
        #expect(try TonAddress(publicKey: privateKey.publicKey, network: network(vector.network)).string
            == vector.address)
    }

    @Test(arguments: loadVectors("ton-transfer") as [TransferVector])
    fileprivate func transferMatchesSdk(_ vector: TransferVector) async throws {
        let net = network(vector.network)
        let privateKey = try PrivateKey(curve: .ed25519, rawBytes: Data(hexString: vector.privateKey))
        let path = try DerivationPath(.ton(net), accountIndex: 0, curve: .ed25519)
        let signer = try TonPKeySigner(network: net, privateKey: privateKey, derivationPath: path)
        let wallet = try signer.address()
        #expect(wallet.string == vector.sender)

        let transport = FakeTonTransport()
        let state = vector.deploy ? "uninitialized" : "active"
        let seqno = String(vector.seqno, radix: 16)
        transport.route(
            "getAddressInformation",
            #"{"ok":true,"result":{"balance":"999999999999999","state":"\#(state)"}}"#
        )

        transport.route("runGetMethod", #"{"ok":true,"result":{"exit_code":0,"stack":[["num","0x\#(seqno)"]]}}"#)

        let issuedAt = Date(
            timeIntervalSince1970: TimeInterval(vector.validUntil) - TonTransactionBuilder.requestLifetime
        )

        let builder = TonTransactionBuilder(
            client: TonClient(network: net, transport: transport),
            publicKey: privateKey.publicKey.rawBytes,
            now: { issuedAt }
        )

        let data = try await builder.buildTransfer(
            sender: wallet,
            recipient: TonAddress(string: vector.recipient),
            amount: #require(BigUInt(vector.amount)),
            token: nil,
            options: vector.comment.map { [.tonComment($0)] } ?? []
        )

        let transaction = try JSONDecoder().decode(TonUnsignedTransaction.self, from: data)

        #expect(hex(try transaction.signingHash()) == vector.signingBodyHash)

        let signature = try await signer.sign(transaction: data)
        #expect(hex(signature) == vector.signature)

        let signedBody = try TonBOC.parse(transaction.body).appending(signature)
        #expect(hex(TonBOC.serialize(signedBody)) == vector.signedBodyBocHex)
        #expect(hex(try transaction.signedMessage(signature: signature)) == vector.externalMessageBocHex)
        #expect(try transaction.normalizedHash(signature: signature) == vector.normalizedHash)
    }
}
