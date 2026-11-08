// Byte-for-byte coverage for the Sui staking PTB builders. The vectors in
// TestVectors/sui-staking-tx.json come from the official @mysten/sui
// TypeScript SDK (Transaction + TransactionDataBuilder.getDigestFromBytes),
// an implementation independent of SuiProgrammableTransaction.swift. The
// Blake2b vectors come from Python's hashlib.

import Foundation
import Testing
@testable import WalletKit

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
    var hex: String { map { String(format: "%02x", $0) }.joined() }
}

private struct StakingVector: Decodable, Sendable, CustomTestStringConvertible {
    let label: String
    let transactionDataBcsHex: String
    let digestHex: String

    var testDescription: String { label }
}

private func loadStakingVectors() -> [StakingVector] {
    let url = Bundle.module.url(forResource: "sui-staking-tx", withExtension: "json")!
    // swiftlint:disable:next force_try
    return try! JSONDecoder().decode([StakingVector].self, from: Data(contentsOf: url))
}

struct Blake2b256Tests {
    private static func input(_ count: Int) -> Data {
        Data((0..<count).map { UInt8(truncatingIfNeeded: $0 * 7 + 1) })
    }

    @Test(arguments: [
        (0, "0e5751c026e543b2e8ab2eb06099daa1d1e5df47778f7787faab45cdf12fe3a8"),
        (3, "e43d000b0a37d6fcddcd15640107181a908675e1820dd5ae307155ffff196ba5"),
        (127, "3b03a73c3c02e3eef11be3e2e16c12ccf6090dea00aa861ded320910892e13ac"),
        (128, "6b89237e0a469a721c700b8bbcb51b6231c48e71ff023e0e3444ec84882ae32e"),
        (129, "524a9dc9d008a9ce1d9d2a111bcd10d2461a02dadf30ec5a47225501608a87eb"),
        (200, "68750259ede3be4895b7b2daee7657821d094106e8378ee645c1f10a4e205c4c"),
        (256, "e7001e3026924e6650fcd5b274bc3ddf556a6c7fedfe038383c0f4ad5f26cfc9")
    ])
    func matchesHashlib(length: Int, expected: String) {
        #expect(Blake2b256.hash(Self.input(length)).hex == expected)
    }
}

struct SuiStakingTransactionsTests {
    private static let vectors = loadStakingVectors()

    private let sender: SuiAddress
    private let validator: SuiAddress
    private let gasCoin = SuiObjectReference(
        objectId: Data(repeating: 0xAA, count: 32), version: 7, digest: Data(repeating: 0xA1, count: 32)
    )

    private let stakedSui = SuiObjectReference(
        objectId: Data(repeating: 0xBB, count: 32), version: 9, digest: Data(repeating: 0xB1, count: 32)
    )

    init() throws {
        sender = try SuiAddress(rawBytes: Data(repeating: 0x11, count: 32))
        validator = try SuiAddress(rawBytes: Data(repeating: 0x22, count: 32))
    }

    private var envelope: SuiStakingEnvelope {
        SuiStakingEnvelope(
            sender: sender, gasPayment: [gasCoin], gasPrice: 1000, gasBudget: 50_000_000, expirationEpoch: 123
        )
    }

    private func vector(_ label: String) throws -> StakingVector {
        try #require(Self.vectors.first { $0.label == label })
    }

    @Test
    func stakeMatchesTheSdk() throws {
        let transaction = try SuiStakingTransactions.stake(
            amount: 5_000_000_000, validator: validator, envelope: envelope
        )

        let expected = try vector("stake 5 SUI")
        #expect(transaction.transactionDataBcs.hex == expected.transactionDataBcsHex.hexDecoded.hex)
        #expect(transaction.digest.hex == expected.digestHex.hexDecoded.hex)
    }

    @Test
    func withdrawMatchesTheSdk() throws {
        let transaction = try SuiStakingTransactions.withdraw(stakedSui: stakedSui, envelope: envelope)
        let expected = try vector("withdraw full")
        #expect(transaction.transactionDataBcs.hex == expected.transactionDataBcsHex.hexDecoded.hex)
        #expect(transaction.digest.hex == expected.digestHex.hexDecoded.hex)
    }

    @Test
    func withdrawPartialMatchesTheSdk() throws {
        let transaction = try SuiStakingTransactions.withdrawPartial(
            stakedSui: stakedSui, amount: 2_500_000_000, envelope: envelope
        )

        let expected = try vector("withdraw partial 2.5 SUI")
        #expect(transaction.transactionDataBcs.hex == expected.transactionDataBcsHex.hexDecoded.hex)
        #expect(transaction.digest.hex == expected.digestHex.hexDecoded.hex)
    }

    @Test
    func walletPolicyDecodesEpochExpirySharedInputsAndMoveCalls() throws {
        let transaction = try SuiStakingTransactions.withdrawPartial(
            stakedSui: stakedSui, amount: 2_500_000_000, envelope: envelope
        )

        let summary = try #require(
            SuiTransactionDataDecoder.summarize(transaction.transactionDataBcs, policy: .wallet)
        )
        #expect(summary.sender == sender)
        #expect(summary.gasBudget == 50_000_000)
        #expect(summary.expirationEpoch == 123)
        #expect(summary.commandCount == 2)
        #expect(summary.moveCalls.map(\.function) == ["split", "request_withdraw_stake"])
        #expect(summary.moveCalls.map(\.module) == ["staking_pool", "sui_system"])
    }

    @Test(arguments: ["stake 5 SUI", "withdraw full", "withdraw partial 2.5 SUI"])
    func dappPolicyStillRejectsStakingShapedBytes(label: String) throws {
        let bytes = try vector(label).transactionDataBcsHex.hexDecoded
        #expect(SuiTransactionDataDecoder.summarize(bytes) == nil)
        #expect(SuiTransactionDataDecoder.summarize(bytes, policy: .wallet) != nil)
    }
}
