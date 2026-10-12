import Foundation
import Testing
import WalletKit

struct EVMBlockchainTests {
    @Test func allMainnetsListsEveryPresetMainnetAndCustom() {
        let expected = EVMBlockchain.presets.filter(\.isMainnet).map(Blockchain.evm) + [.evm(.custom(1))]
        #expect(EVMBlockchain.allMainnets == expected)
    }

    @Test(arguments: EVMBlockchain.presets)
    func allNetworksGroupsSiblingNetworks(_ chain: EVMBlockchain) {
        let networks = chain.allNetworks
        #expect(networks.contains(.evm(chain)))
        #expect(networks.filter(\.isMainnet).count == 1)
        #expect(networks.allSatisfy { network in
            guard case let .evm(sibling) = network else {
                return false
            }

            return sibling.isSameBlockchain(as: chain) && sibling.name == chain.name
        })
    }

    @Test(arguments: EVMBlockchain.presets)
    func codableRoundTrip(_ chain: EVMBlockchain) throws {
        let data = try JSONEncoder().encode(chain)
        #expect(try JSONDecoder().decode(EVMBlockchain.self, from: data) == chain)
    }

    @Test(arguments: EVMBlockchain.presets)
    func initFromChainIdRoundTrips(_ chain: EVMBlockchain) {
        #expect(EVMBlockchain(chainId: chain.chainId) == chain)
    }

    @Test func initFromUnknownChainIdIsCustom() {
        #expect(EVMBlockchain(chainId: 31_337) == .custom(31_337))
    }

    @Test(arguments: EVMBlockchain.presets)
    func nativeTokenIsNative(_ chain: EVMBlockchain) {
        #expect(chain.nativeToken.isNative)
        #expect(chain.nativeToken.decimals == 18)
    }

    @Test func presetChainIdsAreUnique() {
        let chainIds = EVMBlockchain.presets.map(\.chainId)
        #expect(Set(chainIds).count == chainIds.count)
    }

    @Test(arguments: EVMBlockchain.presets)
    func rpcURLIsHTTPS(_ chain: EVMBlockchain) {
        #expect(chain.rpcURL.scheme == "https")
        #expect(chain.rpcURL.host() != "localhost")
    }
}
