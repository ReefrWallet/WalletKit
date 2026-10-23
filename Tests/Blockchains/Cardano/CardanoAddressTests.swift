import Foundation
import Testing
@testable import WalletKit

struct CardanoAddressTests {
    private let entropy = Data(repeating: 0, count: 16)

    @Test func descriptorRoundTripsThroughItsStoredIdentity() throws {
        let descriptor = try CardanoAccountDescriptor(
            entropy: entropy,
            network: .preprod,
            path: .cardanoAccount(accountIndex: 0)
        )

        #expect(try CardanoAccountDescriptor(string: descriptor.string) == descriptor)
    }

    @Test func preprodDescriptorDerivesTestnetPaymentAndStakeAddresses() throws {
        let descriptor = try CardanoAccountDescriptor(
            entropy: entropy,
            network: .preprod,
            path: .cardanoAccount(accountIndex: 0)
        )

        #expect(descriptor.receiveAddress.string.hasPrefix("addr_test"))
        #expect(descriptor.stakeAddress.hasPrefix("stake_test"))
    }

    @Test func addressRejectsANetworkMismatch() throws {
        let descriptor = try CardanoAccountDescriptor(
            entropy: entropy,
            network: .preprod,
            path: .cardanoAccount(accountIndex: 0)
        )

        #expect(throws: WalletKitError.self) {
            _ = try CardanoAddress(string: descriptor.receiveAddress.string, network: .mainnet)
        }
    }

    @Test func descriptorRejectsAnUnknownNetworkIdentifier() {
        #expect(throws: WalletKitError.self) {
            _ = try CardanoAccountDescriptor(string: "cardano:preview:not-an-xpub")
        }
    }
}
