// Runs the shared `TestVectors/aptos-*.json` files (generated with
// `@aptos-labs/ts-sdk` 7.5.0) through the Swift API, mirroring the Rust
// tests in `aptos_signer.rs`.

import Foundation
import Testing
@testable import WalletKit
import WalletKitRust

private struct KeyVector: Decodable, Sendable, CustomTestStringConvertible {
    let label: String
    let scheme: String
    let privateKey: String
    let address: String

    var testDescription: String { label }
    var curve: Curve { scheme == "ed25519" ? .ed25519 : .secp256k1 }
}

private struct DerivationVector: Decodable, Sendable, CustomTestStringConvertible {
    let mnemonic: String
    let scheme: String
    let accountIndex: UInt64
    let path: String
    let address: String

    var testDescription: String { path }
    var curve: Curve { scheme == "ed25519" ? .ed25519 : .secp256k1 }
}

private struct TxVector: Decodable, Sendable, CustomTestStringConvertible {
    let label: String
    let scheme: String
    let privateKey: String
    let rawTransactionBcsHex: String
    let accountAuthenticatorBcsHex: String
    let signedTransactionBcsHex: String
    let transactionHashHex: String

    var testDescription: String { label }
    var curve: Curve { scheme == "ed25519" ? .ed25519 : .secp256k1 }
}

private struct MessageVector: Decodable, Sendable, CustomTestStringConvertible {
    let label: String
    let scheme: String
    let privateKey: String
    let messageHex: String
    let signatureHex: String

    var testDescription: String { label }
    var curve: Curve { scheme == "ed25519" ? .ed25519 : .secp256k1 }
}

private struct TypeTagVector: Decodable, Sendable, CustomTestStringConvertible {
    let typeTag: String
    let bcsHex: String

    var testDescription: String { typeTag }
}

private func loadVectors<T: Decodable>(_ resource: String) -> [T] {
    // swiftlint:disable force_try
    let url = Bundle.module.url(forResource: resource, withExtension: "json")!
    return try! JSONDecoder().decode([T].self, from: Data(contentsOf: url))
    // swiftlint:enable force_try
}

private func signer(_ privateKeyHex: String, curve: Curve) throws -> AptosPKeySigner {
    let privateKey = try PrivateKey(curve: curve, rawBytes: Data(hexString: privateKeyHex))
    return try AptosPKeySigner(
        curve: curve,
        privateKey: privateKey,
        derivationPath: DerivationPath(.aptos(.mainnet), accountIndex: 0, curve: curve)
    )
}

struct AptosVectorTests {
    @Test(arguments: loadVectors("aptos-address") as [KeyVector])
    fileprivate func addressMatchesSdk(_ vector: KeyVector) throws {
        let address = try signer(vector.privateKey, curve: vector.curve).address()
        #expect(address.longString == vector.address)
        #expect(try AptosAddress(string: vector.address) == address)
    }

    @Test(arguments: loadVectors("aptos-tx") as [TxVector])
    fileprivate func publicKeyAndSignatureEncodingMatchSdk(_ vector: TxVector) async throws {
        let signer = try signer(vector.privateKey, curve: vector.curve)
        let accountAuthenticator = try Data(hexString: vector.accountAuthenticatorBcsHex)
        let signature = Data(accountAuthenticator.suffix(64))

        // `AccountAuthenticator` = variant ‖ public key BCS ‖ signature BCS.
        #expect(accountAuthenticator.dropFirst(1) == (try signer.publicKeyBcs()) + signer.signatureBcs(signature))
        #expect(try signer.publicKeyBytes().count == (vector.curve == .ed25519 ? 32 : 65))
    }

    @Test(arguments: loadVectors("aptos-derivation") as [DerivationVector])
    fileprivate func derivedAddressMatchesSdk(_ vector: DerivationVector) throws {
        let path = try DerivationPath(.aptos(.mainnet), accountIndex: vector.accountIndex, curve: vector.curve)
        #expect(path.string == vector.path)

        let key = try Mnemonic.fromPhrase(vector.mnemonic).toSeed().masterKey(curve: vector.curve).derive(path)
        #expect(try AptosAddress(publicKey: key.publicKey, curve: vector.curve).longString == vector.address)
    }

    @Test(arguments: loadVectors("aptos-tx") as [TxVector])
    fileprivate func transactionSignatureMatchesSdk(_ vector: TxVector) async throws {
        let signer = try signer(vector.privateKey, curve: vector.curve)
        let raw = try Data(hexString: vector.rawTransactionBcsHex)

        let authenticator = try await signer.sign(transaction: raw)
        let signed = raw + authenticator
        #expect(signed == (try Data(hexString: vector.signedTransactionBcsHex)))
        // swiftlint:disable:next line_length
        #expect(try await signer.signAccountAuthenticator(transaction: raw) == Data(hexString: vector.accountAuthenticatorBcsHex))
        #expect(AptosClient.transactionHash(of: signed) == vector.transactionHashHex)
    }

    @Test(arguments: loadVectors("aptos-tx") as [TxVector])
    fileprivate func rawTransactionEncodingMatchesSdk(_ vector: TxVector) throws {
        let sender = try signer(vector.privateKey, curve: vector.curve).address()
        let recipient = try AptosAddress(string: "0x" + String(repeating: "ab", count: 32))
        let payload: AptosEntryFunction
        let sequenceNumber: UInt64

        if vector.label.hasSuffix("apt-transfer") {
            payload = .aptTransfer(to: recipient, amount: 123_456_789)
            sequenceNumber = 7
        } else if vector.label.hasSuffix("coin-transfer") {
            payload = .coinTransfer(
                coinType: try MoveType(parsing: AptosClient.nativeCoinType),
                to: recipient,
                amount: 42
            )

            sequenceNumber = 8
        } else {
            payload = .fungibleAssetTransfer(metadata: try AptosAddress(string: "0xa"), to: recipient, amount: 1_000)
            sequenceNumber = 9
        }

        let transaction = AptosRawTransaction(
            sender: sender,
            sequenceNumber: sequenceNumber,
            payload: payload,
            maxGasAmount: 200_000,
            gasUnitPrice: 100,
            expirationTimestampSecs: 1_900_000_000,
            chainId: 4
        )
        #expect(transaction.bcs == (try Data(hexString: vector.rawTransactionBcsHex)))

        let gas = try AptosRawTransaction.gasParameters(of: transaction.bcs)
        #expect(gas.maxGasAmount == 200_000 && gas.gasUnitPrice == 100)
        #expect(try AptosRawTransaction.maxFee(of: transaction.bcs) == 20_000_000)
    }

    @Test(arguments: loadVectors("aptos-tx") as [TxVector])
    fileprivate func rawTransactionDecodingRoundTrips(_ vector: TxVector) throws {
        let bytes = try Data(hexString: vector.rawTransactionBcsHex)
        let transaction = try AptosRawTransaction(bcs: bytes)

        #expect(transaction.bcs == bytes)
        #expect(transaction.sender == (try signer(vector.privateKey, curve: vector.curve).address()))
        #expect(transaction.chainId == 4)
        #expect(transaction.payload.identifier.hasPrefix("0x1::"))

        // Fail closed: truncation, trailing bytes, and non-entry-function payloads.
        #expect(throws: BlockchainClientError.self) { try AptosRawTransaction(bcs: bytes.dropLast()) }
        #expect(throws: BlockchainClientError.self) { try AptosRawTransaction(bcs: bytes + Data([0])) }

        var script = bytes
        script[script.startIndex + 40] = 0
        #expect(throws: BlockchainClientError.self) { try AptosRawTransaction(bcs: script) }
    }

    @Test(arguments: loadVectors("aptos-message") as [MessageVector])
    fileprivate func messageSignatureMatchesSdk(_ vector: MessageVector) async throws {
        let signer = try signer(vector.privateKey, curve: vector.curve)
        let signature = try await signer.sign(message: .aptosMessage(Data(hexString: vector.messageHex)))
        #expect(signature == (try Data(hexString: vector.signatureHex)))
    }

    @Test(arguments: loadVectors("aptos-type-tag") as [TypeTagVector])
    fileprivate func moveTypeEncodingMatchesSdk(_ vector: TypeTagVector) throws {
        let parsed = try MoveType(parsing: vector.typeTag)
        #expect(parsed.bcs == (try Data(hexString: vector.bcsHex)))

        var reader = BCSReader(parsed.bcs)
        #expect(try MoveType(bcs: &reader) == parsed)
        #expect(reader.isAtEnd)
        #expect(parsed.description == vector.typeTag)
    }

    @Test func signerRejectsOtherChainsMessages() async throws {
        let signer = try signer("0x" + String(repeating: "11", count: 32), curve: .ed25519)
        await #expect(throws: WalletKitError.unsupportedFeature) {
            try await signer.sign(message: .suiPersonal(Data([1])))
        }
    }

    @Test func malformedMoveTypesAreRejected() {
        for input in ["", "u7", "0x1::coin", "vector<u8", "0x1::a::B<>", "0x1::1a::B", "0xzz::a::B", "u8 u8"] {
            #expect(throws: BlockchainClientError.self, "\(input)") { try MoveType(parsing: input) }
        }

        let deep = String(repeating: "vector<", count: 17) + "u8" + String(repeating: ">", count: 17)
        #expect(throws: BlockchainClientError.self) { try MoveType(parsing: deep) }
    }
}
