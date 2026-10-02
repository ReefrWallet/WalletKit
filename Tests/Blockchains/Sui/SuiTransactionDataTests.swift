// Hermetic cross-check for SuiTransactionData.swift's hand-rolled BCS
// encoder, against the existing WalletKit/TestVectors/sui-tx.json vectors —
// run before ever trusting the encoder against a live localnet
// (SuiLocalnetTests.swift). No node, no network.
//
// `sui-tx.json`'s `unsignedPtb.commands` field is a human-readable
// description for documentation purposes only — for the multi-transfer
// vector it even truncates recipient addresses ("0x...b0b0") — so it isn't
// parsed here. Instead, `unsignedPtb.transfers` (added alongside
// `gasObjectDigest` specifically for this test) carries the same
// recipients/amounts in full, structured form, extracted from each
// vector's own `transactionDataBcsHex`.

import Foundation
import Testing
import WalletKit

private struct SuiTransferVector: Decodable, Sendable {
    let amount: UInt64
    let recipient: String
}

private struct SuiUnsignedPtbVector: Decodable, Sendable {
    let sender: String
    let transfers: [SuiTransferVector]?
    let gasObjectId: String
    let gasObjectVersion: UInt64
    let gasObjectDigest: String
    let gasPrice: UInt64
    let gasBudget: UInt64
}

private struct SuiPtbTxVector: Decodable, Sendable, CustomTestStringConvertible {
    let label: String
    let unsignedPtb: SuiUnsignedPtbVector
    let transactionDataBcsHex: String

    var testDescription: String { label }
}

private func loadVectors() -> [SuiPtbTxVector] {
    let url = Bundle.module.url(forResource: "sui-tx", withExtension: "json")!
    // swiftlint:disable:next force_try
    let data = try! Data(contentsOf: url)
    // swiftlint:disable:next force_try
    return try! JSONDecoder().decode([SuiPtbTxVector].self, from: data)
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

private extension SuiPtbTxVector {
    /// Builds the `UnsignedSuiTransaction` this vector's `unsignedPtb`
    /// fields describe. `nil` for a vector whose PTB shape (e.g.
    /// `MergeCoins`) isn't a split-and-transfer — `UnsignedSuiTransaction`
    /// deliberately doesn't model those.
    var transaction: UnsignedSuiTransaction? {
        guard let transferVectors = unsignedPtb.transfers else {
            return nil
        }

        // swiftlint:disable force_try
        return UnsignedSuiTransaction(
            sender: try! SuiAddress(string: unsignedPtb.sender),
            transfers: transferVectors.map {
                (recipient: try! SuiAddress(string: $0.recipient), amount: $0.amount)
            },
            gasPayment: [
                SuiObjectReference(
                    objectId: unsignedPtb.gasObjectId.hexDecoded,
                    version: unsignedPtb.gasObjectVersion,
                    digest: unsignedPtb.gasObjectDigest.hexDecoded
                )
            ],
            gasOwner: try! SuiAddress(string: unsignedPtb.sender),
            gasPrice: unsignedPtb.gasPrice,
            gasBudget: unsignedPtb.gasBudget
        )
        // swiftlint:enable force_try
    }
}

struct SuiTransactionDataTests {
    // secp256r1-merge-coins is excluded: its PTB is a `MergeCoins` command,
    // which `UnsignedSuiTransaction` doesn't model, so `.transaction` is
    // `nil` for it.
    fileprivate static let vectors = loadVectors().filter { $0.transaction != nil }

    @Test(arguments: vectors)
    fileprivate func transactionDataBcsMatchesTheVectorsExpectedBytes(vector: SuiPtbTxVector) throws {
        let transaction = try #require(vector.transaction)
        #expect(transaction.transactionDataBcs.hexEncoded == vector.transactionDataBcsHex)
    }
}
