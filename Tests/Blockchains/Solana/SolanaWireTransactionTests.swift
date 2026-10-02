import Foundation
import Testing
@testable import WalletKit

struct SolanaWireTransactionTests {
    private func address(_ byte: UInt8) throws -> SolanaAddress {
        try SolanaAddress(rawBytes: Data(repeating: byte, count: 32))
    }

    // MARK: - Fixtures

    /// A real legacy `Message`, built and serialized the same way the
    /// app's own outbound transactions are, with a single required signer
    /// (`payer`).
    private func validLegacyMessageBytes() throws -> (bytes: Data, payer: SolanaAddress) {
        let payer = try address(1)
        let recipient = try address(2)
        let message = try SolanaMessage.compile(
            payer: payer,
            instructions: [SystemProgram.transfer(from: payer, to: recipient, lamports: 1_000)],
            recentBlockhash: Data(repeating: 9, count: 32)
        )
        return (message.serialize(), payer)
    }

    private func wrapAsTransaction(messageBytes: Data, signatures: [Data]) -> Data {
        var tx = SolanaShortVec.encode(signatures.count)
        for signature in signatures {
            tx.append(signature)
        }
        tx.append(messageBytes)
        return tx
    }

    /// A hand-built version-0 message: 2 static accounts (`payer`,
    /// `SolanaProgram.system`), one instruction referencing a
    /// loaded-writable account by index, and one address-table lookup
    /// loading 1 writable account — so `totalAccountCount == 3` while
    /// only 2 accounts are listed statically.
    private func validV0MessageBytes() throws -> (bytes: Data, payer: SolanaAddress) {
        let payer = try address(1)
        let programId = SolanaProgram.system

        var data = Data([0x80]) // version-0 prefix
        data.append(contentsOf: [1, 0, 1]) // header: 1 required signer, 0 readonly-signed, 1 readonly-unsigned
        data.append(SolanaShortVec.encode(2)) // static account count
        data.append(payer.rawBytes)
        data.append(programId.rawBytes)
        data.append(Data(repeating: 7, count: 32)) // recentBlockhash
        data.append(SolanaShortVec.encode(1)) // instruction count
        data.append(1) // programIdIndex -> programId (static index 1)
        data.append(SolanaShortVec.encode(2)) // instruction account count
        data.append(contentsOf: [UInt8(0), UInt8(2)]) // payer (static 0), loaded-writable (index 2)
        data.append(SolanaShortVec.encode(1)) // instruction data length
        data.append(Data([0xAB]))
        data.append(SolanaShortVec.encode(1)) // address table lookup count
        data.append(Data(repeating: 0xEE, count: 32)) // lookup table account key
        data.append(SolanaShortVec.encode(1)) // writable index count
        data.append(Data([5]))
        data.append(SolanaShortVec.encode(0)) // readonly index count

        return (data, payer)
    }

    // MARK: - Round trips

    @Test func parsesARealLegacyTransactionBuiltFromSolanaMessage() throws {
        let (messageBytes, payer) = try validLegacyMessageBytes()
        let signature = Data(repeating: 0xAA, count: 64)
        let tx = try SolanaWireTransaction(parsing: wrapAsTransaction(messageBytes: messageBytes, signatures: [signature]))

        #expect(tx.version == .legacy)
        #expect(tx.signatures == [signature])
        #expect(tx.staticAccountKeys.first == payer)
        #expect(tx.header.numRequiredSignatures == 1)
        #expect(tx.addressTableLookupCount == 0)
        #expect(tx.totalAccountCount == tx.staticAccountKeys.count)
        #expect(tx.messageBytes == messageBytes)
    }

    @Test func parsesAHandBuiltV0TransactionWithLookupIndexes() throws {
        let (messageBytes, payer) = try validV0MessageBytes()
        let signature = Data(repeating: 0xBB, count: 64)
        let tx = try SolanaWireTransaction(parsing: wrapAsTransaction(messageBytes: messageBytes, signatures: [signature]))

        #expect(tx.version == .v0)
        #expect(tx.staticAccountKeys == [payer, SolanaProgram.system])
        #expect(tx.addressTableLookupCount == 1)
        #expect(tx.addressTableLookups.first?.writableIndexes == [5])
        #expect(tx.addressTableLookups.first?.readonlyIndexes == [])
        #expect(tx.totalAccountCount == 3) // 2 static + 1 loaded-writable
    }

    @Test func sharedParserAgreesWithWireTransactionForLegacyAndV0Messages() throws {
        for (messageBytes, _) in [try validLegacyMessageBytes(), try validV0MessageBytes()] {
            let tx = try SolanaWireTransaction(parsing: wrapAsTransaction(messageBytes: messageBytes, signatures: [Data(repeating: 1, count: 64)]))
            let standalone = try SolanaParsedMessage(validating: messageBytes)
            #expect(tx.parsedMessage == standalone)
        }
    }

    // MARK: - Truncation / trailing bytes

    @Test func everyProperPrefixOfAValidLegacyMessageFailsToParse() throws {
        let (full, _) = try validLegacyMessageBytes()
        for length in 0..<full.count {
            #expect(throws: WalletKitError.self) {
                _ = try SolanaParsedMessage(validating: full.prefix(length))
            }
        }
    }

    @Test func everyProperPrefixOfAValidV0MessageFailsToParse() throws {
        let (full, _) = try validV0MessageBytes()
        for length in 0..<full.count {
            #expect(throws: WalletKitError.self) {
                _ = try SolanaParsedMessage(validating: full.prefix(length))
            }
        }
    }

    @Test func rejectsTrailingBytesAfterAFullyParsedMessage() throws {
        let (full, _) = try validLegacyMessageBytes()
        var withTrailingByte = full
        withTrailingByte.append(0x00)
        #expect(throws: WalletKitError.self) {
            _ = try SolanaParsedMessage(validating: withTrailingByte)
        }
    }

    // MARK: - Shortvec canonicality / bounds

    @Test func rejectsANonCanonicalStaticAccountCountShortvec() {
        // Header (0 required signers) followed by a non-canonical 2-byte
        // encoding of the static-account count `2` (`0x02` would be
        // canonical).
        let data = Data([0, 0, 0]) + Data([0x82, 0x00])
        #expect(throws: WalletKitError.self) {
            _ = try SolanaParsedMessage(validating: data)
        }
    }

    @Test func rejectsAStaticAccountCountShortvecAboveTheCompactU16Ceiling() {
        let data = Data([0, 0, 0]) + Data([0xFF, 0xFF, 0x04])
        #expect(throws: WalletKitError.self) {
            _ = try SolanaParsedMessage(validating: data)
        }
    }

    @Test func rejectsAStaticAccountCountThatExceedsTheRemainingInput() {
        // Claims 5 static accounts but supplies none.
        let data = Data([0, 0, 0, 0x05])
        #expect(throws: WalletKitError.self) {
            _ = try SolanaParsedMessage(validating: data)
        }
    }

    @Test func rejectsAnUnknownVersionPrefix() {
        // 0x81 signals version 1, which isn't supported.
        let data = Data([0x81, 0, 0, 0]) + SolanaShortVec.encode(0) + Data(repeating: 0, count: 32) + SolanaShortVec.encode(0)
        #expect(throws: WalletKitError.self) {
            _ = try SolanaParsedMessage(validating: data)
        }
    }

    // MARK: - Header consistency

    @Test func rejectsHeaderWhereReadonlySignedExceedsRequiredSignatures() throws {
        var data = Data([1, 2, 0]) // numRequiredSignatures=1, numReadonlySignedAccounts=2 (> 1)
        data.append(SolanaShortVec.encode(2))
        data.append(try address(1).rawBytes)
        data.append(try address(2).rawBytes)
        data.append(Data(repeating: 0, count: 32))
        data.append(SolanaShortVec.encode(0))
        #expect(throws: WalletKitError.self) {
            _ = try SolanaParsedMessage(validating: data)
        }
    }

    @Test func rejectsHeaderWhereReadonlyUnsignedOverflowsTheRemainingAccounts() throws {
        var data = Data([1, 0, 5]) // 2 static accounts, but 5 claimed readonly-unsigned
        data.append(SolanaShortVec.encode(2))
        data.append(try address(1).rawBytes)
        data.append(try address(2).rawBytes)
        data.append(Data(repeating: 0, count: 32))
        data.append(SolanaShortVec.encode(0))
        #expect(throws: WalletKitError.self) {
            _ = try SolanaParsedMessage(validating: data)
        }
    }

    // MARK: - Instruction validation

    @Test func rejectsAProgramIdIndexOutsideTheStaticAccountKeySet() throws {
        var data = Data([1, 0, 0])
        data.append(SolanaShortVec.encode(1))
        data.append(try address(1).rawBytes)
        data.append(Data(repeating: 0, count: 32))
        data.append(SolanaShortVec.encode(1))
        data.append(1) // programIdIndex == staticAccountKeys.count (out of range)
        data.append(SolanaShortVec.encode(0))
        data.append(SolanaShortVec.encode(0))
        #expect(throws: WalletKitError.self) {
            _ = try SolanaParsedMessage(validating: data)
        }
    }

    @Test func rejectsAnInstructionAccountIndexEqualToTotalAccountCount() throws {
        var data = Data([1, 0, 0])
        data.append(SolanaShortVec.encode(1))
        data.append(try address(1).rawBytes)
        data.append(Data(repeating: 0, count: 32))
        data.append(SolanaShortVec.encode(1))
        data.append(0) // programIdIndex -> the one static account
        data.append(SolanaShortVec.encode(1))
        data.append(1) // accountIndex == totalAccountCount (1), out of range
        data.append(SolanaShortVec.encode(0))
        #expect(throws: WalletKitError.self) {
            _ = try SolanaParsedMessage(validating: data)
        }
    }

    @Test func totalAccountCountExceedingTheOneByteIndexSpaceIsRejected() throws {
        let payer = try address(1)
        var data = Data([0x80]) // v0
        data.append(contentsOf: [1, 0, 0])
        data.append(SolanaShortVec.encode(1))
        data.append(payer.rawBytes)
        data.append(Data(repeating: 0, count: 32))
        data.append(SolanaShortVec.encode(0)) // no instructions
        data.append(SolanaShortVec.encode(1)) // one lookup
        data.append(Data(repeating: 0xEE, count: 32))
        data.append(SolanaShortVec.encode(255)) // 255 loaded-writable
        data.append(Data(repeating: 0, count: 255))
        data.append(SolanaShortVec.encode(1)) // 1 loaded-readonly -> total = 1 + 255 + 1 = 257
        data.append(Data([0]))
        #expect(throws: WalletKitError.self) {
            _ = try SolanaParsedMessage(validating: data)
        }
    }

    // MARK: - signed(by:)

    private func twoSignerLegacyMessageBytes() throws -> (bytes: Data, signerA: SolanaAddress, signerB: SolanaAddress) {
        let signerA = try address(1)
        let signerB = try address(2)
        var data = Data([2, 0, 0]) // 2 required signers, both writable
        data.append(SolanaShortVec.encode(2))
        data.append(signerA.rawBytes)
        data.append(signerB.rawBytes)
        data.append(Data(repeating: 0, count: 32))
        data.append(SolanaShortVec.encode(0))
        return (data, signerA, signerB)
    }

    @Test func signedReplacesOnlyTheTargetSignerSlotPreservingCoSigners() throws {
        let (messageBytes, _, signerB) = try twoSignerLegacyMessageBytes()
        let sigA = Data(repeating: 0x11, count: 64)
        let sigB = Data(repeating: 0x22, count: 64)
        let tx = try SolanaWireTransaction(parsing: wrapAsTransaction(messageBytes: messageBytes, signatures: [sigA, sigB]))

        let newSigB = Data(repeating: 0x33, count: 64)
        let updatedBytes = try tx.signed(by: signerB, signature: newSigB)
        let updated = try SolanaWireTransaction(parsing: updatedBytes)

        #expect(updated.signatures == [sigA, newSigB])
        #expect(updated.messageBytes == messageBytes)
    }

    @Test func signedRejectsAnAddressThatIsNotARequiredSigner() throws {
        let (messageBytes, _, _) = try twoSignerLegacyMessageBytes()
        let tx = try SolanaWireTransaction(
            parsing: wrapAsTransaction(messageBytes: messageBytes, signatures: [Data(repeating: 1, count: 64), Data(repeating: 2, count: 64)])
        )
        let outsider = try address(9)
        #expect(throws: WalletKitError.self) {
            _ = try tx.signed(by: outsider, signature: Data(repeating: 3, count: 64))
        }
    }

    @Test func signedRejectsANonSixtyFourByteSignature() throws {
        let (messageBytes, signerA, _) = try twoSignerLegacyMessageBytes()
        let tx = try SolanaWireTransaction(
            parsing: wrapAsTransaction(messageBytes: messageBytes, signatures: [Data(repeating: 1, count: 64), Data(repeating: 2, count: 64)])
        )
        #expect(throws: WalletKitError.self) {
            _ = try tx.signed(by: signerA, signature: Data(repeating: 3, count: 10))
        }
    }

    // MARK: - Transaction-level signature/header consistency

    @Test func rejectsASignatureCountThatDoesNotMatchNumRequiredSignatures() throws {
        let (messageBytes, _) = try validLegacyMessageBytes() // numRequiredSignatures == 1
        let tx = wrapAsTransaction(
            messageBytes: messageBytes, signatures: [Data(repeating: 1, count: 64), Data(repeating: 2, count: 64)]
        )
        #expect(throws: WalletKitError.self) {
            _ = try SolanaWireTransaction(parsing: tx)
        }
    }

    @Test func rejectsATransactionExceedingTheMaximumWireSize() throws {
        let (messageBytes, _) = try validLegacyMessageBytes()
        let padded = messageBytes + Data(repeating: 0, count: SolanaParsedMessage.maxWireSize)
        #expect(throws: WalletKitError.self) {
            _ = try SolanaParsedMessage(validating: padded)
        }
    }
}
