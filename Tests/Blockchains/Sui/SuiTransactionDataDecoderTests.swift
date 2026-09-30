// Adversarial + real-vector coverage for SuiTransactionDataDecoder.swift.
// Real vectors come from WalletKit/TestVectors/sui-tx.json (built with
// `sui client ptb ... --serialize-unsigned-transaction` against a local
// `sui start` test validator — see that file's per-vector notes), which
// between them exercise every CallArg/Command/Argument variant this
// decoder implements (Pure, Object(ImmOrOwned), SplitCoins,
// TransferObjects, MergeCoins). Synthetic vectors below cover every
// unimplemented/unknown-variant rejection path, canonical-ULEB128
// enforcement, bounded collection counts, trailing-byte rejection, and
// truncation at every byte boundary.

import Foundation
import Testing
import WalletKit

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

// MARK: - Real-vector coverage

private struct RealVector: Decodable, Sendable, CustomTestStringConvertible {
    let label: String
    let unsignedPtb: UnsignedPtb
    let transactionDataBcsHex: String

    struct UnsignedPtb: Decodable, Sendable {
        let sender: String
        let commands: [String]
        let gasPrice: UInt64
        let gasBudget: UInt64
    }

    var testDescription: String { label }
}

private func loadRealVectors() -> [RealVector] {
    let url = Bundle.module.url(forResource: "sui-tx", withExtension: "json")!
    // swiftlint:disable:next force_try
    let data = try! Data(contentsOf: url)
    // swiftlint:disable:next force_try
    return try! JSONDecoder().decode([RealVector].self, from: data)
}

struct SuiTransactionDataDecoderRealVectorTests {
    fileprivate static let vectors = loadRealVectors()

    @Test(arguments: vectors)
    fileprivate func summaryMatchesTheVectorsExpectedFields(vector: RealVector) throws {
        let summary = try #require(SuiTransactionDataDecoder.summarize(vector.transactionDataBcsHex.hexDecoded))
        #expect(summary.sender.string == vector.unsignedPtb.sender)
        #expect(summary.gasPrice == vector.unsignedPtb.gasPrice)
        #expect(summary.gasBudget == vector.unsignedPtb.gasBudget)
        #expect(summary.commandCount == vector.unsignedPtb.commands.count)
    }
}

// MARK: - Round-trip against this repo's own builders (necessary, not sufficient)

struct SuiTransactionDataDecoderRoundTripTests {
    private static let account = try! SuiAddress(rawBytes: Data(repeating: 0x11, count: 32)) // swiftlint:disable:this force_try
    private static let recipient = try! SuiAddress(rawBytes: Data(repeating: 0x22, count: 32)) // swiftlint:disable:this force_try
    private static let coinA = SuiObjectReference(
        objectId: Data(repeating: 0x33, count: 32), version: 1, digest: Data(repeating: 0x44, count: 32)
    )
    private static let coinB = SuiObjectReference(
        objectId: Data(repeating: 0x55, count: 32), version: 2, digest: Data(repeating: 0x66, count: 32)
    )
    private static let gasCoin = SuiObjectReference(
        objectId: Data(repeating: 0x77, count: 32), version: 3, digest: Data(repeating: 0x88, count: 32)
    )

    @Test func nativeSplitTransferRoundTrips() throws {
        let transaction = UnsignedSuiTransaction(
            sender: Self.account, transfers: [(recipient: Self.recipient, amount: 42)],
            gasPayment: [Self.gasCoin], gasOwner: Self.account, gasPrice: 1000, gasBudget: 3_000_000
        )
        let summary = try #require(SuiTransactionDataDecoder.summarize(transaction.transactionDataBcs))
        #expect(summary.sender == Self.account)
        #expect(summary.gasPrice == 1000)
        #expect(summary.gasBudget == 3_000_000)
        #expect(summary.commandCount == 2) // SplitCoins + TransferObjects
    }

    @Test func wholeCoinObjectTransferRoundTrips() throws {
        let transaction = UnsignedCoinObjectTransfer(
            sender: Self.account, coinObject: Self.coinA, recipient: Self.recipient,
            gasPayment: [Self.gasCoin], gasOwner: Self.account, gasPrice: 1000, gasBudget: 2_000_000
        )
        let summary = try #require(SuiTransactionDataDecoder.summarize(transaction.transactionDataBcs))
        #expect(summary.commandCount == 1) // TransferObjects
        #expect(summary.gasBudget == 2_000_000)
    }

    @Test func singleCoinSplitTransferRoundTrips() throws {
        let transaction = UnsignedSingleCoinSplitTransfer(
            sender: Self.account, coinObject: Self.coinA, amount: 7, recipient: Self.recipient,
            gasPayment: [Self.gasCoin], gasOwner: Self.account, gasPrice: 1000, gasBudget: 2_000_000
        )
        let summary = try #require(SuiTransactionDataDecoder.summarize(transaction.transactionDataBcs))
        #expect(summary.commandCount == 2) // SplitCoins + TransferObjects
    }

    @Test func multiCoinMergeSplitTransferRoundTrips() throws {
        let transaction = UnsignedMultiCoinMergeSplitTransfer(
            sender: Self.account, coinObjects: [Self.coinA, Self.coinB], amount: 9, recipient: Self.recipient,
            gasPayment: [Self.gasCoin], gasOwner: Self.account, gasPrice: 1000, gasBudget: 2_000_000
        )
        let summary = try #require(SuiTransactionDataDecoder.summarize(transaction.transactionDataBcs))
        #expect(summary.commandCount == 3) // MergeCoins + SplitCoins + TransferObjects
    }
}

// MARK: - Adversarial / fail-closed coverage

struct SuiTransactionDataDecoderAdversarialTests {
    private static let accountBytes = Data(repeating: 0xAB, count: 32)
    private static let gasObjectId = Data(repeating: 0xCD, count: 32)
    private static let gasDigest = Data(repeating: 0xEF, count: 16)

    /// Builds a syntactically valid `TransactionData::V1` blob with no
    /// inputs and `commands` as its raw (already-encoded) commands
    /// section — the base every adversarial test mutates from.
    private static func validTransaction(commandCount: Int, commands: Data) -> Data {
        var data = Data([0x00, 0x00]) // V1, ProgrammableTransaction
        data += Data([0x00]) // 0 inputs
        data += BCS.uleb128(commandCount)
        data += commands
        data += accountBytes
        data += Data([0x01]) // 1 gas payment reference
        data += gasObjectId
        data += BCS.u64(1) // version
        data += BCS.byteVector(gasDigest)
        data += accountBytes // gas owner
        data += BCS.u64(1000) // price
        data += BCS.u64(3_000_000) // budget
        data += Data([0x00]) // TransactionExpiration::None
        return data
    }

    /// Same shape as `validTransaction`, but with a caller-supplied
    /// inputs section instead of zero inputs — used by the `CallArg`/
    /// `ObjectArg` adversarial tests below.
    private static func validTransactionWithInputs(inputCount: Int, inputs: Data) -> Data {
        var data = Data([0x00, 0x00]) // V1, ProgrammableTransaction
        data += BCS.uleb128(inputCount)
        data += inputs
        data += Data([0x00]) // 0 commands
        data += accountBytes
        data += Data([0x00]) // 0 gas payment references
        data += accountBytes // gas owner
        data += BCS.u64(1000) // price
        data += BCS.u64(3_000_000) // budget
        data += Data([0x00]) // TransactionExpiration::None
        return data
    }

    @Test func emptyProgrammableTransactionDecodes() throws {
        let data = Self.validTransaction(commandCount: 0, commands: Data())
        let summary = try #require(SuiTransactionDataDecoder.summarize(data))
        #expect(summary.gasPrice == 1000)
        #expect(summary.gasBudget == 3_000_000)
        #expect(summary.commandCount == 0)
    }

    @Test func wrongTransactionDataVariantFailsClosed() {
        var data = Self.validTransaction(commandCount: 0, commands: Data())
        data[0] = 0x01 // not V1
        #expect(SuiTransactionDataDecoder.summarize(data) == nil)
    }

    @Test func wrongTransactionKindFailsClosed() {
        var data = Self.validTransaction(commandCount: 0, commands: Data())
        data[1] = 0x01 // not ProgrammableTransaction
        #expect(SuiTransactionDataDecoder.summarize(data) == nil)
    }

    @Test func nonNoneExpirationFailsClosed() {
        var data = Self.validTransaction(commandCount: 0, commands: Data())
        data[data.count - 1] = 0x01 // Epoch, not None
        #expect(SuiTransactionDataDecoder.summarize(data) == nil)
    }

    @Test func trailingBytesFailClosed() {
        let data = Self.validTransaction(commandCount: 0, commands: Data()) + Data([0xFF])
        #expect(SuiTransactionDataDecoder.summarize(data) == nil)
    }

    @Test func unknownCommandTagFailsClosed() {
        // MoveCall (tag 0) — a real Sui command, but not one this
        // decoder implements.
        let data = Self.validTransaction(commandCount: 1, commands: Data([0x00]))
        #expect(SuiTransactionDataDecoder.summarize(data) == nil)
    }

    @Test func publishUpgradeMakeMoveVecCommandTagsFailClosed() {
        for tag: UInt8 in [0x04, 0x05, 0x06] { // Publish, MakeMoveVec, Upgrade
            let data = Self.validTransaction(commandCount: 1, commands: Data([tag]))
            #expect(SuiTransactionDataDecoder.summarize(data) == nil)
        }
    }

    @Test func unknownArgumentTagFailsClosed() {
        // TransferObjects(Vec<Argument> with one unknown-tagged Argument, Argument)
        let commands = Data([0x01, 0x01, 0xFF])
        let data = Self.validTransaction(commandCount: 1, commands: commands)
        #expect(SuiTransactionDataDecoder.summarize(data) == nil)
    }

    @Test func unknownCallArgTagFailsClosed() {
        // FundsWithdrawal (tag 2) — a real, current Sui CallArg variant
        // this decoder doesn't implement.
        let data = Self.validTransactionWithInputs(inputCount: 1, inputs: Data([0x02]))
        #expect(SuiTransactionDataDecoder.summarize(data) == nil)
    }

    @Test func sharedObjectArgVariantFailsClosed() {
        // CallArg::Object, ObjectArg::SharedObject
        let data = Self.validTransactionWithInputs(inputCount: 1, inputs: Data([0x01, 0x01]))
        #expect(SuiTransactionDataDecoder.summarize(data) == nil)
    }

    @Test func nonCanonicalUleb128FailsClosed() {
        // 0 encoded as [0x80, 0x00] — a redundant continuation byte for
        // a value that fits in one byte. Used here as the input count.
        var data = Data([0x00, 0x00])
        data += Data([0x80, 0x00]) // non-canonical ULEB128 for 0
        data += Data([0x00]) // 0 commands
        data += Self.accountBytes
        data += Data([0x00])
        data += Self.accountBytes
        data += BCS.u64(1000)
        data += BCS.u64(3_000_000)
        data += Data([0x00])
        #expect(SuiTransactionDataDecoder.summarize(data) == nil)
    }

    @Test func oversizedCollectionCountFailsClosed() {
        var data = Data([0x00, 0x00])
        data += BCS.uleb128(5000) // exceeds the 4096 bound, as an input count
        data += Data([0x00])
        data += Self.accountBytes
        data += Data([0x00])
        data += Self.accountBytes
        data += BCS.u64(1000)
        data += BCS.u64(3_000_000)
        data += Data([0x00])
        #expect(SuiTransactionDataDecoder.summarize(data) == nil)
    }

    @Test func truncationAtEveryByteBoundaryNeverTrapsAndNeverDecodes() {
        let full = Self.validTransaction(
            commandCount: 1,
            commands: Data([0x02, 0x00, 0x01, 0x01, 0x00, 0x00]) // SplitCoins(GasCoin, [Input(0)])
        )
        #expect(SuiTransactionDataDecoder.summarize(full) != nil)
        for length in 0..<full.count {
            #expect(SuiTransactionDataDecoder.summarize(full.prefix(length)) == nil)
        }
    }

    @Test func emptyDataFailsClosed() {
        #expect(SuiTransactionDataDecoder.summarize(Data()) == nil)
    }

    @Test func oversizedTotalPayloadFailsClosed() {
        let huge = Data(repeating: 0, count: 300 * 1024)
        #expect(SuiTransactionDataDecoder.summarize(huge) == nil)
    }
}
