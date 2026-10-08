// Spec-driven test for Docs/Design Specification/Core/MnemonicWordCount.swift.
// Will compile once the corresponding type is exported from Sources.

import Testing
@testable import WalletKit

struct MnemonicWordCountTests {
    @Test(arguments: [
        (MnemonicWordCount.`12`, UInt32(12)),
        (MnemonicWordCount.`15`, UInt32(15)),
        (MnemonicWordCount.`18`, UInt32(18)),
        (MnemonicWordCount.`21`, UInt32(21)),
        (MnemonicWordCount.`24`, UInt32(24))
    ])
    func rawValueMatchesWordCount(count: MnemonicWordCount, expected: UInt32) {
        #expect(count.rawValue == expected)
    }

    @Test func allCasesHasFiveEntries() {
        #expect(MnemonicWordCount.allCases.count == 5)
    }
}
