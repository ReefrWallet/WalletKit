// Spec-driven test for Docs/Design Specification/Core/Wordlist.swift.
// Will compile once the corresponding type is exported from Sources.

import Testing
@testable import WalletKit
import WalletKitRust

struct WordlistTests {
    @Test func allCasesIncludesEnglish() {
        #expect(Wordlist.allCases.contains(.english))
    }
}
