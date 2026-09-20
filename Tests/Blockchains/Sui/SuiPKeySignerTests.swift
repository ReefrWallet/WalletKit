// Spec-driven test for Docs/Design Specification/Clients/Sui/SuiSigner.swift.
// See "Testing strategy" in Docs/Overview.md.
//
// Runs the same two shared vector files as the Rust side
// (Rust/walletkit-ffi/src/blockchain_clients/{sui_address,sui_signer}.rs)
// through the exported `SuiPKeySigner`, so both sides of the FFI boundary
// are checked against identical expected output.
//
// sui-address.json was generated with the official `sui keytool generate
// <scheme> --json` (Sui CLI 1.66.2) — see that file for how each entry's
// `privateKey` was recovered from the tool's own keypair file.
// sui-tx.json was generated from real Programmable Transaction Blocks
// built with `sui client ptb ... --serialize-unsigned-transaction`
// against a local `sui start` test validator, signed with `sui keytool
// sign`, and independently confirmed with both `sui keytool
// decode-or-verify-tx` and `sui client execute-signed-tx` — see that file
// for the full provenance note per vector.
//
// secp256r1 vectors are present in both files but skipped here: `Curve`
// has no case for that scheme (see `common::Curve` on the Rust side), so
// there's no `PrivateKey`/`SuiPKeySigner` to drive through — the Rust tests
// cover that scheme's address/signing formulas directly instead.
//
// The tx vectors are keyed by raw private keys, not mnemonics/derivation
// paths, so tests import them via `PrivateKey(curve:rawBytes:)` and attach
// the chain's standard SLIP-10 path to build a `SuiPKeySigner`.

import Foundation
import Testing
@testable import WalletKit
import WalletKitRust

private struct SuiAddressVector: Decodable, Sendable, CustomTestStringConvertible {
    let label: String
    let scheme: String
    let privateKey: String
    let publicKey: String
    let address: String

    var testDescription: String { label }

    var curve: Curve? {
        switch scheme {
        case "ed25519": return .ed25519
        case "secp256k1": return .secp256k1
        default: return nil
        }
    }
}

private struct SuiTxVector: Decodable, Sendable, CustomTestStringConvertible {
    let label: String
    let scheme: String
    let privateKey: String
    let transactionDataBcsHex: String
    let signatureHex: String

    var testDescription: String { label }

    var curve: Curve? {
        switch scheme {
        case "ed25519": return .ed25519
        case "secp256k1": return .secp256k1
        default: return nil
        }
    }
}

private func loadVectors<T: Decodable>(_ resource: String) -> [T] {
    // swiftlint:disable force_try
    let url = Bundle.module.url(forResource: resource, withExtension: "json")!
    let data = try! Data(contentsOf: url)
    return try! JSONDecoder().decode([T].self, from: data)
    // swiftlint:enable force_try
}

private extension String {
    /// Decodes a `0x`-prefixed (or bare) hex string, as used throughout the
    /// Sui test vector files.
    var hexDecoded: Data {
        let hex = hasPrefix("0x") ? String(dropFirst(2)) : self
        var data = Data(capacity: hex.count / 2)
        var index = hex.startIndex
        while index < hex.endIndex {
            let next = hex.index(index, offsetBy: 2, limitedBy: hex.endIndex) ?? hex.endIndex
            data.append(UInt8(hex[index..<next], radix: 16)!)
            index = next
        }
        return data
    }
}

private extension Data {
    var hexEncoded: String {
        "0x" + map { String(format: "%02x", $0) }.joined()
    }
}

struct SuiPKeySignerTests {
    fileprivate static let vectors: [SuiAddressVector] = loadVectors("sui-address")
    fileprivate static let supportedVectors = vectors.filter { $0.curve != nil }
    fileprivate static let txVectors: [SuiTxVector] = loadVectors("sui-tx")
    fileprivate static let supportedTxVectors = txVectors.filter { $0.curve != nil }

    private static let derivationPath = TestAccountFactory.slip10Path(coinType: 784)

    @Test(arguments: supportedVectors)
    fileprivate func addressMatchesTheVectorsExpectedAddress(vector: SuiAddressVector) throws {
        let curve = try #require(vector.curve)
        let privateKey = try PrivateKey(curve: curve, rawBytes: vector.privateKey.hexDecoded)

        // Sanity check: the vector's private key derives the vector's own
        // public key, cross-checking this test's key import.
        #expect(privateKey.publicKey.rawBytes == vector.publicKey.hexDecoded)

        let address = try SuiAddress(publicKey: privateKey.publicKey, curve: curve)
        #expect(address.string == vector.address)
    }

    @Test func accountCarriesTheRequestedPathCurveAndSource() throws {
        let curve = Curve.ed25519
        let privateKey = try PrivateKey(curve: curve, rawBytes: Data(repeating: 1, count: 32))
        let signer = try SuiPKeySigner(curve: curve, privateKey: privateKey, derivationPath: Self.derivationPath)
        #expect(signer.account.derivationPath == Self.derivationPath)
        #expect(signer.account.curve == curve)
        #expect(signer.account.source == .software)
    }

    @Test func curveDefaultsToEd25519() throws {
        let privateKey = try PrivateKey(curve: .ed25519, rawBytes: Data(repeating: 1, count: 32))
        let signer = try SuiPKeySigner(privateKey: privateKey, derivationPath: Self.derivationPath)
        #expect(signer.curve == .ed25519)
        #expect(signer.blockchain == .sui(.mainnet))
    }

    @Test func blockchainReflectsTheConfiguredCurve() throws {
        let privateKey = try PrivateKey(curve: .secp256k1, rawBytes: Data(repeating: 1, count: 32))
        let signer = try SuiPKeySigner(
            curve: .secp256k1,
            privateKey: privateKey,
            derivationPath: Self.derivationPath
        )
        #expect(signer.blockchain == .sui(.mainnet))
    }

    @Test func initRejectsACurveMismatch() throws {
        let ed25519Key = try PrivateKey(curve: .ed25519, rawBytes: Data(repeating: 7, count: 32))
        #expect(throws: WalletKitError.self) {
            _ = try SuiPKeySigner(curve: .secp256k1, privateKey: ed25519Key, derivationPath: Self.derivationPath)
        }
    }

    @Test(arguments: supportedTxVectors)
    fileprivate func signProducesTheVectorsExpectedSignature(vector: SuiTxVector) async throws {
        let curve = try #require(vector.curve)
        let privateKey = try PrivateKey(curve: curve, rawBytes: vector.privateKey.hexDecoded)
        let signer = try SuiPKeySigner(curve: curve, privateKey: privateKey, derivationPath: Self.derivationPath)

        let signature = try await signer.sign(transaction: vector.transactionDataBcsHex.hexDecoded)
        #expect(signature.hexEncoded == vector.signatureHex)
    }
}
