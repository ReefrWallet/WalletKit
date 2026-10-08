// Hermetic cross-check for LegacyTransaction.swift's hand-rolled RLP
// encoder, against the existing WalletKit/TestVectors/ethereum-tx.json
// vectors — run before ever trusting the encoder against a live Anvil node
// (EthereumAnvilTests.swift). No Anvil, no network.

import BigInt
import Foundation
import Testing
@testable import WalletKit

private struct EthereumTxVector: Decodable, Sendable, CustomTestStringConvertible {
    struct UnsignedTxFields: Decodable, Sendable {
        let nonce: Int
        let gasPrice: String
        let gasLimit: Int
        let to: String
        let value: String
        let data: String
    }

    let label: String
    let chainId: UInt64
    let unsignedTx: UnsignedTxFields
    let signingDataHex: String

    var testDescription: String { label }
}

private func loadTxVectors() -> [EthereumTxVector] {
    let url = Bundle.module.url(forResource: "ethereum-tx", withExtension: "json")!
    // swiftlint:disable force_try force_cast
    let raw = try! Data(contentsOf: url)
    let all = try! JSONSerialization.jsonObject(with: raw) as! [[String: Any]]
    let legacyRaw = all.filter { ($0["type"] as? Int) != 2 }
    return try! JSONDecoder().decode(
        [EthereumTxVector].self,
        from: try! JSONSerialization.data(withJSONObject: legacyRaw)
    )

    // swiftlint:enable force_try force_cast
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

private extension EthereumTxVector {
    /// Builds the `UnsignedLegacyTransaction` this vector's `unsignedTx`
    /// fields describe.
    var transaction: UnsignedLegacyTransaction {
        // swiftlint:disable force_try
        UnsignedLegacyTransaction(
            nonce: BigUInt(unsignedTx.nonce),
            gasPrice: BigUInt(unsignedTx.gasPrice, radix: 10)!,
            gasLimit: BigUInt(unsignedTx.gasLimit),
            to: try! EthereumAddress(string: unsignedTx.to),
            value: BigUInt(unsignedTx.value, radix: 10)!,
            data: unsignedTx.data.hexDecoded,
            chainId: chainId
        )

        // swiftlint:enable force_try
    }
}

struct LegacyTransactionTests {
    fileprivate static let vectors = loadTxVectors()

    @Test(arguments: vectors)
    fileprivate func signingDataMatchesTheVectorsExpectedRLP(vector: EthereumTxVector) {
        #expect(vector.transaction.signingData.hexEncoded == vector.signingDataHex)
    }

    @Test func signingDataOfAContractCreationHasAnEmptyToField() {
        // None of the three ethereum-tx.json vectors exercise `to == nil`
        // (contract creation) — the shape EthereumAnvilTests' MockUSDC
        // deploy needs — so this is checked independently: RLP represents
        // "no address" as an empty byte string, `0x80`.
        let deploy = UnsignedLegacyTransaction(
            nonce: 0,
            gasPrice: 1,
            gasLimit: 100_000,
            to: nil,
            value: 0,
            data: Data([0xFE, 0xED]),
            chainId: 31337
        )

        // RLP([0x80, 0x01, 0x830186a0, 0x80, 0x80, 0x82feed, 0x827a69, 0x80, 0x80]),
        // computed by hand from the encoding rules in LegacyTransaction.swift.
        let expected = Data([
            0xD0,
            0x80, // nonce 0
            0x01, // gasPrice 1
            0x83, 0x01, 0x86, 0xA0, // gasLimit 100_000
            0x80, // to: empty (contract creation)
            0x80, // value 0
            0x82, 0xFE, 0xED, // data
            0x82, 0x7A, 0x69, // chainId 31337
            0x80, // r placeholder
            0x80 // s placeholder
        ])
        #expect(deploy.signingData == expected)
    }
}
