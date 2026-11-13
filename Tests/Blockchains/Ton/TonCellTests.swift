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
