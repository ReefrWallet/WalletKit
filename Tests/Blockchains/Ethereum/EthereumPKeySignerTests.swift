// Spec-driven test for Docs/Design Specification/Clients/EthereumSigner.swift.
// See "Testing strategy" in Docs/Overview.md.
//
// Runs the same two shared vector files as the Rust side
// (Rust/walletkit-ffi/src/blockchain_clients/{ethereum_address,ethereum_signer}.rs)
// through the exported `EthereumPKeySigner`, so both sides of the FFI
// boundary are checked against identical expected output.
//
// The vectors are keyed by raw private keys, not mnemonics/derivation
// paths, so tests import them via `PrivateKey(curve:rawBytes:)` and attach
// the chain's standard BIP44 path to build an `EthereumPKeySigner` — the
// signer's `account.derivationPath` is therefore asserted rather than one
// the key was actually derived at.

import Foundation
import Testing
@testable import WalletKit

private struct EthereumAddressVector: Decodable, Sendable, CustomTestStringConvertible {
    let label: String
    let privateKey: String
    let address: String

    var testDescription: String { label }
}

private struct EthereumTxVector: Decodable, Sendable, CustomTestStringConvertible {
    let label: String
    let privateKey: String
    let chainId: UInt64
    let signingDataHex: String
    let signingHashHex: String
    let address: String
    let signedTxHex: String

    var testDescription: String { label }
}

private func loadVectors<T: Decodable>(_ resource: String) -> [T] {
    let url = Bundle.module.url(forResource: resource, withExtension: "json")!
    // swiftlint:disable force_try
    let data = try! Data(contentsOf: url)
    return try! JSONDecoder().decode([T].self, from: data)
    // swiftlint:enable force_try
}

private extension String {
    /// Decodes a `0x`-prefixed (or bare) hex string, as used throughout the
    /// Ethereum test vector files.
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

struct EthereumPKeySignerTests {
    fileprivate static let addressVectors: [EthereumAddressVector] = loadVectors("ethereum-address")
    fileprivate static let txVectors: [EthereumTxVector] = loadVectors("ethereum-tx")

    private static let derivationPath = TestAccountFactory.bip44Path(coinType: 60)

    @Test(arguments: addressVectors)
    fileprivate func addressMatchesTheVectorsExpectedChecksummedAddress(vector: EthereumAddressVector) throws {
        let privateKey = try PrivateKey(curve: .secp256k1, rawBytes: vector.privateKey.hexDecoded)
        let address = try EthereumAddress(publicKey: privateKey.publicKey)
        #expect(address.checksummed == vector.address)
        #expect(address.string == vector.address)
    }

    @Test func accountCarriesTheRequestedPathCurveAndSource() throws {
        let privateKey = try PrivateKey(curve: .secp256k1, rawBytes: Self.addressVectors[0].privateKey.hexDecoded)
        let signer = try EthereumPKeySigner(privateKey: privateKey, derivationPath: Self.derivationPath)
        #expect(signer.account.derivationPath == Self.derivationPath)
        #expect(signer.account.curve == .secp256k1)
        #expect(signer.account.source == .software)
    }

    @Test(arguments: txVectors)
    fileprivate func signProducesTheVectorsExpectedSignedTransaction(vector: EthereumTxVector) async throws {
        let privateKey = try PrivateKey(curve: .secp256k1, rawBytes: vector.privateKey.hexDecoded)
        let signer = try EthereumPKeySigner(
            chainId: vector.chainId,
            privateKey: privateKey,
            derivationPath: Self.derivationPath
        )

        // Sanity check: the vector's signing key also derives the vector's
        // own address, cross-checking this test's private-key import
        // against EthereumAddressTests'/the address vectors' coverage.
        let address = try signer.address()
        #expect(address.checksummed == vector.address)

        let signed = try await signer.sign(transaction: vector.signingDataHex.hexDecoded)
        #expect(signed.hexEncoded == vector.signedTxHex)
    }

    @Test func signRejectsAChainIdMismatch() async throws {
        // Vector 0 is mainnet (chain id 1); configure the signer for a
        // different network so it must refuse to sign — a signer scoped to
        // one network shouldn't silently sign for another.
        let vector = Self.txVectors[0]
        let privateKey = try PrivateKey(curve: .secp256k1, rawBytes: vector.privateKey.hexDecoded)
        let signer = try EthereumPKeySigner(
            chainId: vector.chainId + 1,
            privateKey: privateKey,
            derivationPath: Self.derivationPath
        )

        await #expect(throws: WalletKitError.self) {
            _ = try await signer.sign(transaction: vector.signingDataHex.hexDecoded)
        }
    }

    @Test func blockchainReflectsTheConfiguredChainId() throws {
        let privateKey = try PrivateKey(curve: .secp256k1, rawBytes: Self.addressVectors[0].privateKey.hexDecoded)
        let mainnet = try EthereumPKeySigner(privateKey: privateKey, derivationPath: Self.derivationPath)
        #expect(mainnet.blockchain == .evm(.ethereum(.mainnet)))

        let sepolia = try EthereumPKeySigner(
            chainId: 11_155_111,
            privateKey: privateKey,
            derivationPath: Self.derivationPath
        )

        #expect(sepolia.blockchain == .evm(.ethereum(.sepolia)))
    }

    @Test func initRejectsAnEd25519Key() throws {
        let privateKey = try PrivateKey(curve: .ed25519, rawBytes: Data(repeating: 7, count: 32))
        #expect(throws: WalletKitError.self) {
            _ = try EthereumPKeySigner(privateKey: privateKey, derivationPath: Self.derivationPath)
        }
    }
}
