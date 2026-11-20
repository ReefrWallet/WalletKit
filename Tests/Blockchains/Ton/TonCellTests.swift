import BigInt
import Foundation
import Testing
@testable import WalletKit

struct TonCellTests {
    @Test func bocRoundTripsAndSharesCells() throws {
        var leaf = TonCellBuilder()
        leaf.storeUInt(0b101, bits: 3)
        let shared = try leaf.build()
        var root = TonCellBuilder()
        root.storeUInt(0xABCD, bits: 16)
        root.storeRef(shared)
        root.storeRef(shared)
        let cell = try root.build()

        let parsed = try TonBOC.parse(TonBOC.serialize(cell))
        #expect(parsed == cell)
        #expect(parsed.refs.count == 2)
        #expect(parsed.refs[0].bitCount == 3)
    }

    /// A BoC header with the given sizes and values, followed by `tail`.
    private func header(refSize: Int, offsetSize: Int, cells: [UInt8], body: [UInt8], tail: [UInt8] = []) -> Data {
        let root = [UInt8](repeating: 0, count: refSize - 1) + [1]
        let absent = [UInt8](repeating: 0, count: refSize)
        var bytes: [UInt8] = [0xB5, 0xEE, 0x9C, 0x72, UInt8(refSize), UInt8(offsetSize)]
        bytes += cells + root + absent + body + absent + tail
        return Data(bytes)
    }

    @Test func aHeaderDeclaringMoreThanTheBytesHoldIsRejectedNotTrapped() {
        // A body size of Int.max: position + count would overflow before any bounds check.
        let huge = header(refSize: 1, offsetSize: 8, cells: [1], body: [0x7F] + [UInt8](repeating: 0xFF, count: 7))
        #expect(throws: WalletKitError.self) { try TonBOC.parse(huge) }

        // The largest size a number may have (7 bytes), still far past the data.
        let large = header(refSize: 1, offsetSize: 7, cells: [1], body: [UInt8](repeating: 0xFF, count: 7))
        #expect(throws: WalletKitError.self) { try TonBOC.parse(large) }

        // Billions of cells declared in a handful of bytes.
        let many = header(
            refSize: 7, offsetSize: 1,
            cells: [0x00, 0x7F, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF], body: [4], tail: [0, 0, 0, 0]
        )

        #expect(throws: WalletKitError.self) { try TonBOC.parse(many) }
    }

    @Test func anEightByteSizeFieldIsValidWhenItsValueFits() throws {
        // One empty cell, its two-byte body declared in an eight-byte field.
        let data = header(refSize: 1, offsetSize: 8, cells: [1], body: [0, 0, 0, 0, 0, 0, 0, 2], tail: [0, 0])
        #expect(try TonBOC.parse(data).hash == TonCell.empty.hash)
    }

    @Test func aReferenceChainDeeperThanTheLimitIsRejectedWhileItIsBuilt() throws {
        // Valid references, 1 100 cells long: each cell holds one reference to the next.
        let count = 1_100
        var body: [UInt8] = []

        for index in 0 ..< count - 1 {
            body += [0x01, 0x00, UInt8((index + 1) >> 8), UInt8((index + 1) & 0xFF)]
        }

        body += [0x00, 0x00]
        let size = [UInt8(body.count >> 24), UInt8((body.count >> 16) & 0xFF), UInt8((body.count >> 8) & 0xFF),
                    UInt8(body.count & 0xFF)]

        let cells = [UInt8(count >> 8), UInt8(count & 0xFF)]
        let data = header(refSize: 2, offsetSize: 4, cells: cells, body: size, tail: body)
        #expect(throws: WalletKitError.self) { try TonBOC.parse(data) }

        // The same chain through the builder.
        var cell = TonCell.empty

        #expect(throws: WalletKitError.self) {
            for _ in 0 ... TonCell.maxDepth {
                var builder = TonCellBuilder()
                builder.storeRef(cell)
                cell = try builder.build()
            }
        }
    }

    @Test func emptyCellHashMatchesTheKnownValue() {
        #expect(TonCell.empty.hash.map { String(format: "%02x", $0) }.joined()
            == "96a296d224f285c67bee93c30f8a309157f0daa35dc5b87e410b78630a09cfc7")
    }

    @Test func rejectsTooManyBitsAndReferences() throws {
        var builder = TonCellBuilder()
        builder.storeBytes(Data(repeating: 0, count: 128))
        #expect(throws: WalletKitError.self) { try builder.build() }

        var refs = TonCellBuilder()
        (0..<5).forEach { _ in refs.storeRef(.empty) }
        #expect(throws: WalletKitError.self) { try refs.build() }
    }

    @Test func storesCoinsAsVarUInteger() throws {
        var builder = TonCellBuilder()
        builder.storeCoins(BigUInt(1_000_000_000))
        let cell = try builder.build()
        #expect(cell.bitCount == 4 + 32)
        #expect(cell.bits == Data([0x43, 0xB9, 0xAC, 0xA0, 0x00]))
    }

    @Test func v5r1CodeHashMatchesTheContract() {
        #expect(TonWalletV5R1.code.hash.map { String(format: "%02x", $0) }.joined()
            == "20834b7b72b112147e1b2fb457b84e74d1a30f04f737d4f62a668e9552d2b72f")
    }

    @Test func v5r1WalletIdIsNetworkSpecific() {
        #expect(TonWalletV5R1.walletId(network: .mainnet) == 2_147_483_409)
        #expect(TonWalletV5R1.walletId(network: .mainnet) != TonWalletV5R1.walletId(network: .testnet))
    }
}
