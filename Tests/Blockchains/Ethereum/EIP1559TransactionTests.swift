// Hermetic cross-check for UnsignedEIP1559Transaction's hand-rolled RLP
// signingData encoder and EthereumPKeySigner's EIP-1559 signing dispatch,
// against the type-2 entries in WalletKit/TestVectors/ethereum-tx.json.
// No Anvil, no network — runs identically to LegacyTransactionTests.swift
// but exercises the 0x02-prefixed type-2 path end to end.

import BigInt
import Foundation
import Testing
@testable import WalletKit

private struct EIP1559TxVector: Decodable, Sendable, CustomTestStringConvertible {
    struct UnsignedTxFields: Decodable, Sendable {
        let nonce: Int
        let maxPriorityFeePerGas: String
        let maxFeePerGas: String
        let gasLimit: Int
        let to: String
        let value: String
        let data: String
    }

    let label: String
    let privateKey: String
    let chainId: UInt64
    let unsignedTx: UnsignedTxFields
    let signingDataHex: String
    let address: String
    let signedTxHex: String

    var testDescription: String { label }
}

private func loadEIP1559Vectors() -> [EIP1559TxVector] {
    let url = Bundle.module.url(forResource: "ethereum-tx", withExtension: "json")!
    // swiftlint:disable force_try force_cast
    let raw = try! Data(contentsOf: url)
    let all = try! JSONSerialization.jsonObject(with: raw) as! [[String: Any]]
    let eip1559Raw = all.filter { ($0["type"] as? Int) == 2 }
    return try! JSONDecoder().decode(
        [EIP1559TxVector].self,
        from: try! JSONSerialization.data(withJSONObject: eip1559Raw)
    )
    // swiftlint:enable force_try force_cast
}

private extension String {
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
    var hexEncoded: String { "0x" + map { String(format: "%02x", $0) }.joined() }
}

private let eip1559DerivationPath = TestAccountFactory.bip44Path(coinType: 60)

struct EIP1559TransactionTests {
    fileprivate static let vectors = loadEIP1559Vectors()

    /// Verifies that the Swift RLP encoder produces exactly the `signingDataHex`
    /// value from the test vector — the same preimage the Rust signer hashes.
    @Test(arguments: vectors)
    fileprivate func signingDataMatchesTheVectorsExpectedRLP(vector: EIP1559TxVector) throws {
        // swiftlint:disable force_try
        let tx = UnsignedEIP1559Transaction(
            nonce: BigUInt(vector.unsignedTx.nonce),
            maxPriorityFeePerGas: BigUInt(vector.unsignedTx.maxPriorityFeePerGas, radix: 10)!,
            maxFeePerGas: BigUInt(vector.unsignedTx.maxFeePerGas, radix: 10)!,
            gasLimit: BigUInt(vector.unsignedTx.gasLimit),
            to: try! EthereumAddress(string: vector.unsignedTx.to),
            value: BigUInt(vector.unsignedTx.value, radix: 10)!,
            data: vector.unsignedTx.data.hexDecoded,
            chainId: vector.chainId
        )
        // swiftlint:enable force_try
        #expect(tx.signingData.hexEncoded == vector.signingDataHex)
    }

    /// Verifies that EthereumPKeySigner routes on the 0x02 prefix and produces
    /// the expected `signedTxHex` — the complete, broadcastable type-2 tx.
    @Test(arguments: vectors)
    fileprivate func signProducesTheVectorsExpectedSignedTransaction(vector: EIP1559TxVector) async throws {
        let privateKey = try PrivateKey(curve: .secp256k1, rawBytes: vector.privateKey.hexDecoded)
        let signer = try EthereumPKeySigner(
            chainId: vector.chainId,
            privateKey: privateKey,
            derivationPath: eip1559DerivationPath
        )

        let address = try signer.address()
        #expect(address.checksummed == vector.address)

        let signed = try await signer.sign(transaction: vector.signingDataHex.hexDecoded)
        #expect(signed.hexEncoded == vector.signedTxHex)
    }
}
