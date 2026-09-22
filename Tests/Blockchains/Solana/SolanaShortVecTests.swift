import Foundation
import Testing
@testable import WalletKit

struct SolanaShortVecTests {
    @Test(arguments: [
        (0, [UInt8(0x00)]),
        (1, [UInt8(0x01)]),
        (127, [UInt8(0x7F)]),
        (128, [UInt8(0x80), 0x01]),
        (16_383, [UInt8(0xFF), 0x7F]),
        (16_384, [UInt8(0x80), 0x80, 0x01]),
        (65_535, [UInt8(0xFF), 0xFF, 0x03])
    ])
    func encodesKnownVectors(value: Int, expectedBytes: [UInt8]) {
        #expect(SolanaShortVec.encode(value) == Data(expectedBytes))
    }

    @Test func decodeInvertsEncodeAcrossAllThreeByteLengths() throws {
        for value in [0, 1, 127, 128, 16_383, 16_384, 65_535] {
            let encoded = SolanaShortVec.encode(value)
            var offset = 0
            let decoded = try SolanaShortVec.decode(encoded, offset: &offset)
            #expect(decoded == value)
            #expect(offset == encoded.count)
        }
    }

    @Test func decodeAdvancesOffsetPastOnlyItsOwnBytes() throws {
        var data = SolanaShortVec.encode(300)
        data.append(0xAB)
        var offset = 0
        let decoded = try SolanaShortVec.decode(data, offset: &offset)
        #expect(decoded == 300)
        #expect(data[offset] == 0xAB)
    }

    @Test func decodeThrowsOnTruncatedInput() {
        // 0x80 always signals "more bytes follow" — a lone 0x80 byte is
        // truncated by definition.
        #expect(throws: WalletKitError.self) {
            var offset = 0
            _ = try SolanaShortVec.decode(Data([0x80]), offset: &offset)
        }
    }
}
