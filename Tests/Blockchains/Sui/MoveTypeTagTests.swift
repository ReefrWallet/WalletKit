// Tests for Sources/Static/Blockchains/Sui/MoveTypeTag.swift — generic
// type-argument splitting and coin-type address normalization.

import Testing
@testable import WalletKit

struct MoveTypeTagTests {
    // MARK: - genericTypeArguments

    @Test func genericTypeArgumentsSplitsTwoSimpleCoinTypes() throws {
        let typeTag = "0x1eabed72::pool::Pool<0x2::sui::SUI, 0xdba34672::usdc::USDC>"
        #expect(try MoveTypeTag.genericTypeArguments(of: typeTag) == ["0x2::sui::SUI", "0xdba34672::usdc::USDC"])
    }

    @Test func genericTypeArgumentsRespectsNestedAngleBracketsWhenSplitting() throws {
        // A generic coin type's own type argument contains a comma-free
        // nested `<...>` here, but the splitter must not be fooled by a
        // nested comma either — this fabricated inner type exercises that.
        let typeTag = "0xabc::pool::Pool<0x2::coin::COIN<0xdef::a::A, 0xdef::b::B>, 0x2::sui::SUI>"
        #expect(try MoveTypeTag.genericTypeArguments(of: typeTag) == [
            "0x2::coin::COIN<0xdef::a::A, 0xdef::b::B>",
            "0x2::sui::SUI"
        ])
    }

    @Test func genericTypeArgumentsThrowsWhenThereAreNoGenericArguments() {
        #expect(throws: BlockchainClientError.self) {
            _ = try MoveTypeTag.genericTypeArguments(of: "0x2::sui::SUI")
        }
    }

    // MARK: - canonicalCoinType

    @Test func canonicalCoinTypePadsAShortAddressToSixtyFourHexDigits() throws {
        let expected = "0x0000000000000000000000000000000000000000000000000000000000000002::sui::SUI"
        #expect(try MoveTypeTag.canonicalCoinType("0x2::sui::SUI") == expected)
    }

    @Test func canonicalCoinTypeLeavesAnAlreadyLongAddressUnchangedApartFromCasing() throws {
        let long = "0x0000000000000000000000000000000000000000000000000000000000000002::sui::SUI"
        #expect(try MoveTypeTag.canonicalCoinType(long) == long)
    }

    @Test func canonicalCoinTypeLowercasesTheAddress() throws {
        let expected = "0x00000000000000000000000000000000000000000000000000000000000000ab::mod::Type"
        #expect(try MoveTypeTag.canonicalCoinType("0xAB::mod::Type") == expected)
    }

    @Test func canonicalCoinTypeOfShortAndLongFormsOfTheSameCoinAreEqual() throws {
        let short = try MoveTypeTag.canonicalCoinType("0x2::sui::SUI")
        let long = try MoveTypeTag.canonicalCoinType(
            "0x0000000000000000000000000000000000000000000000000000000000000002::sui::SUI"
        )
        #expect(short == long)
    }

    @Test func canonicalCoinTypeThrowsWhenThereIsNoAddressSeparator() {
        #expect(throws: BlockchainClientError.self) {
            _ = try MoveTypeTag.canonicalCoinType("not-a-coin-type")
        }
    }
}
