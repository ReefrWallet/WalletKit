import Foundation
import Testing
@testable import WalletKit

struct TronAddressTests {
    private let genesisAddress = "T9yD14Nj9j7xAB4dbGeiX9h8unkKHxuWwb"

    @Test func base58CheckVectorRoundTrips() throws {
        let address = try TronAddress(string: genesisAddress)
        #expect(address.rawBytes == Data([0x41]) + Data(repeating: 0, count: 20))
        #expect(address.string == genesisAddress)
    }

    @Test func rejectsAnInvalidChecksum() {
        #expect(throws: WalletKitError.self) {
            _ = try TronAddress(string: "T9yD14Nj9j7xAB4dbGeiX9h8unkKHxuWwa")
        }
    }

    @Test func rejectsAnInvalidNetworkPrefix() {
        #expect(throws: WalletKitError.self) {
            _ = try TronAddress(rawBytes: Data(repeating: 0, count: 21))
        }
    }
}
