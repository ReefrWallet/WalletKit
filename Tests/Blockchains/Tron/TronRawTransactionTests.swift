import Foundation
import Testing
@testable import WalletKit

/// `raw_data_hex` vectors produced by TronWeb 6.5.1's `txJsonToPb` +
/// `txPbToRawDataHex`.
struct TronRawTransactionTests {
    static let transferHex =
        "0A02E94222086394747DA9FEE42140C08AFEE680335A68080112640A2D747970652E676F6F676C65617069732E636F6D"
        + "2F70726F746F636F6C2E5472616E73666572436F6E747261637412330A15417E5F4552091A69125D5DFCB7B8C2659029"
        + "395BDF121541A614F803B6FD780986A42C78EC9C7F77E6DED13C18C095D20870E0B5FAE68033"

    static let triggerHex =
        "0A02E94222086394747DA9FEE42140C08AFEE680335AAE01081F12A9010A31747970652E676F6F676C65617069732E63"
        + "6F6D2F70726F746F636F6C2E54726967676572536D617274436F6E747261637412740A15417E5F4552091A69125D5DFC"
        + "B7B8C2659029395BDF121541A614F803B6FD780986A42C78EC9C7F77E6DED13C2244A9059CBB00000000000000000000"
        + "0000A614F803B6FD780986A42C78EC9C7F77E6DED13C0000000000000000000000000000000000000000000000000000"
        + "0000000F424070E0B5FAE68033900180A3C347"

    /// The same call with `call_value` 5 TRX and a `memo` data field.
    static let triggerWithCallValueHex =
        "0A02E94222086394747DA9FEE42140C08AFEE6803352046D656D6F5AB301081F12AE010A31747970652E676F6F676C65"
        + "617069732E636F6D2F70726F746F636F6C2E54726967676572536D617274436F6E747261637412790A15417E5F455209"
        + "1A69125D5DFCB7B8C2659029395BDF121541A614F803B6FD780986A42C78EC9C7F77E6DED13C18C096B1022244A9059C"
        + "BB000000000000000000000000A614F803B6FD780986A42C78EC9C7F77E6DED13C000000000000000000000000000000"
        + "00000000000000000000000000000F424070E0B5FAE68033900180A3C347"

    static let owner = "TMVQGm1qAQYVdetCeGRRkTWYYrLXuHK2HC"
    static let usdt = "TR7NHqjeKQxGTCi8q8ZY4pL8otSzgjLj6t"

    @Test func decodesATransfer() throws {
        let transaction = try TronRawTransaction(rawBytes: Data(hexString: Self.transferHex))

        #expect(transaction.contract == .transfer(
            owner: try TronAddress(string: Self.owner),
            to: try TronAddress(string: Self.usdt),
            amount: 18_123_456
        ))
        #expect(transaction.expiration == 1_752_562_632_000)
        #expect(transaction.timestamp == 1_752_562_572_000)
        #expect(transaction.feeLimit == nil)
        #expect(transaction.memo == nil)
        #expect(transaction.txId.bareHex == "f8a1a2643092bb6ea25abe580aae387b385e7a724ad4487c65958ab96131ae73")
    }

    @Test func decodesATriggerSmartContractWithCallValueAndMemo() throws {
        let transaction = try TronRawTransaction(rawBytes: Data(hexString: Self.triggerWithCallValueHex))

        guard case let .triggerSmartContract(owner, contract, callValue, data) = transaction.contract else {
            Issue.record("expected a TriggerSmartContract")
            return
        }

        #expect(owner == (try TronAddress(string: Self.owner)))
        #expect(contract == (try TronAddress(string: Self.usdt)))
        #expect(callValue == 5_000_000)
        #expect(data.prefix(4) == Data([0xa9, 0x05, 0x9c, 0xbb]))
        #expect(transaction.feeLimit == 150_000_000)
        #expect(transaction.memo == Data("memo".utf8))
        #expect(transaction.txId.bareHex == "9bfefb057a410ac09da5fc88ae1c7075f7f4d74c671b041227d36d9fedb9a2da")
    }

    /// The Trezor path rebuilds `raw_data` from the envelope; it must
    /// reproduce the original bytes exactly.
    @Test(arguments: [transferHex, triggerHex])
    func signingEnvelopeRebuildsTheSameRawData(hex: String) throws {
        let transaction = try TronRawTransaction(rawBytes: Data(hexString: hex))
        #expect(transaction.isTrezorReproducible)
    }

    @Test func envelopeCarriesTheDecodedFields() throws {
        let transaction = try TronRawTransaction(rawBytes: Data(hexString: Self.triggerWithCallValueHex))
        let envelope = try JSONSerialization.jsonObject(with: transaction.signingEnvelope()) as? [String: Any]

        #expect(envelope?["raw_data_hex"] as? String == Self.triggerWithCallValueHex.lowercased())
        #expect(envelope?["txID"] as? String == transaction.txId.bareHex)

        let rawData = envelope?["raw_data"] as? [String: Any]
        #expect(rawData?["data"] as? String == "6d656d6f")
        #expect(rawData?["fee_limit"] as? UInt64 == 150_000_000)
    }

    @Test func rejectsTrailingBytes() throws {
        let bytes = try Data(hexString: Self.transferHex) + Data([0x00])
        #expect(throws: BlockchainClientError.self) { try TronRawTransaction(rawBytes: bytes) }
    }

    @Test func rejectsRepeatedFields() throws {
        // A second `expiration` (field 8) after the original.
        let bytes = try Data(hexString: Self.transferHex) + Data([0x40, 0x01])
        #expect(throws: BlockchainClientError.self) { try TronRawTransaction(rawBytes: bytes) }
    }

    @Test func rejectsUnknownFields() throws {
        // `scripts` (field 12).
        let bytes = try Data(hexString: Self.transferHex) + Data([0x62, 0x01, 0x00])
        #expect(throws: BlockchainClientError.self) { try TronRawTransaction(rawBytes: bytes) }
    }

    @Test func rejectsTruncatedInput() throws {
        let bytes = try Data(hexString: Self.transferHex).dropLast(3)
        #expect(throws: BlockchainClientError.self) { try TronRawTransaction(rawBytes: Data(bytes)) }
    }

    @Test func rejectsAMismatchedTypeURL() throws {
        let hex = Self.transferHex.replacingOccurrences(of: "5472616E73666572", with: "5472616E73666571")
        #expect(throws: BlockchainClientError.self) { try TronRawTransaction(rawBytes: Data(hexString: hex)) }
    }
}
