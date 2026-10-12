import BigInt
import Foundation
import Testing
@testable import WalletKit

/// A well-known contract on a live network: an ERC-20 whose metadata is
/// checked, plus an address known to hold native coin.
private struct LiveFixture {
    let decimals: UInt8
    let nativeHolder: String
    let symbol: String
    let token: String

    /// Paxos USDG, with the ERC-4337 EntryPoint v0.7 as the native holder.
    static func usdg(_ token: String) -> Self {
        let entryPointV07 = "0x0000000071727De22E5E9d8BAf0edAc6f37da032"
        return LiveFixture(decimals: 6, nativeHolder: entryPointV07, symbol: "USDG", token: token)
    }

    /// A wrapped native token: an ERC-20 that also holds the wrapped coin.
    static func wrapped(_ token: String, symbol: String) -> Self {
        LiveFixture(decimals: 18, nativeHolder: token, symbol: symbol, token: token)
    }
}

private let multicall3 = "0xcA11bde05977b3631167028862bE2a173976CA11"
private let opStackWETH = "0x4200000000000000000000000000000000000006"

/// Exhaustive on purpose: a new ``EVMBlockchain`` preset fails to compile
/// until it gets a live fixture.
private func liveFixture(for chain: EVMBlockchain) -> LiveFixture? {
    switch chain {
    case let .arbitrum(network):
        switch network {
        case .mainnet: .wrapped("0x82aF49447D8a07e3bd95BD0d56f35241523fBab1", symbol: "WETH")
        case .sepolia: .wrapped("0x980B62Da83eFf3D4576C647993b0c1D7faf17c73", symbol: "WETH")
        }

    case let .avalanche(network):
        switch network {
        case .fuji: .wrapped("0xd00ae08403B9bbb9124bB305C09058E32C39A48c", symbol: "WAVAX")
        case .mainnet: .wrapped("0xB31f66AA3C1e785363F0875A1B74E27b85FD66c7", symbol: "WAVAX")
        }

    case .base, .optimism, .unichain:
        .wrapped(opStackWETH, symbol: "WETH")

    case let .bsc(network):
        switch network {
        case .mainnet: .wrapped("0xbb4CdB9CBd36B01bD1cBaEBF2De08d9173bc095c", symbol: "WBNB")
        case .testnet: .wrapped("0xae13d989daC2f0dEbFf460aC112a837C89BAa7cd", symbol: "WBNB")
        }

    case let .ethereum(network):
        switch network {
        case .mainnet: .wrapped("0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2", symbol: "WETH")
        case .sepolia: .wrapped("0xfFf9976782d46CC05630D1f6eBAb18b2324d6B14", symbol: "WETH")
        }

    case .hyperEVM:
        .wrapped("0x5555555555555555555555555555555555555555", symbol: "WHYPE")

    case let .mantle(network):
        switch network {
        case .mainnet: .wrapped("0x78c1b0C915c4FAA5FffA6CAbf0219DA63d7f4cb8", symbol: "WMNT")
        case .sepolia: .wrapped("0x19f5557E23e9914A18239990f6C70D68FDF0deD5", symbol: "WMNT")
        }

    case let .monad(network):
        switch network {
        case .mainnet: .wrapped("0x3bd359C1119dA7Da1D913D1C4D2B7c461115433A", symbol: "WMON")
        case .testnet: .wrapped("0xFb8bf4c1CC7a94c73D209a149eA2AbEa852BC541", symbol: "WMON")
        }

    case let .polygon(network):
        switch network {
        case .amoy: .wrapped("0x360ad4f9a9A8EFe9A8DCB5f461c4Cc1047E1Dcf9", symbol: "WPOL")
        case .mainnet: .wrapped("0x0d500B1d8E8eF31E21C99d1Db9A6444d3ADf1270", symbol: "WPOL")
        }

    // No canonical WETH: Paxos USDG, plus the ERC-4337 EntryPoint for native ETH.
    case let .robinhood(network):
        switch network {
        case .mainnet: .usdg("0x5fc5360D0400a0Fd4f2af552ADD042D716F1d168")
        case .testnet: .usdg("0x7E955252E15c84f5768B83c41a71F9eba181802F")
        }

    case .custom:
        nil
    }
}

private func makeClient(_ chain: EVMBlockchain) -> EthereumRPCClient {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.timeoutIntervalForRequest = 10
    let session = URLSession(configuration: configuration)
    return EthereumRPCClient(endpoint: chain.rpcURL, chainId: chain.chainId, session: session)
}

private func rawResult(_ client: EthereumRPCClient, _ method: String, _ params: String = "[]") async throws -> String {
    let data = try await client.request(method: method, params: Data(params.utf8))
    return try JSONDecoder().decode(String.self, from: data)
}

private let skipsLiveNetworkTests = LocalNodeTesting.isRunningInCI
    && ProcessInfo.processInfo.environment["LIVE_NETWORK_TESTS"] != "1"

/// Hits each preset's public RPC. Skipped in CI unless `LIVE_NETWORK_TESTS=1`.
@Suite(.disabled(if: skipsLiveNetworkTests, "Talks to public RPC endpoints"), .timeLimit(.minutes(1)))
struct EVMBlockchainLiveTests {
    @Test(arguments: EVMBlockchain.presets)
    func endpointServesTheExpectedChain(_ chain: EVMBlockchain) async throws {
        let chainId = try await rawResult(makeClient(chain), "eth_chainId")
        #expect(UInt64(chainId.dropFirst(2), radix: 16) == chain.chainId)
    }

    @Test(arguments: EVMBlockchain.presets)
    func feeRatesAreAvailable(_ chain: EVMBlockchain) async throws {
        let fees = try await makeClient(chain).feeRates()
        #expect(fees.gasPrice > 0)
        #expect(fees.maxFeePerGas > 0)
    }

    @Test(arguments: EVMBlockchain.presets)
    func multicall3IsDeployed(_ chain: EVMBlockchain) async throws {
        let code = try await rawResult(makeClient(chain), "eth_getCode", #"["\#(multicall3)","latest"]"#)
        #expect(code.count > 2)
    }

    @Test(arguments: EVMBlockchain.presets)
    func readsNativeBalanceOfAWellKnownHolder(_ chain: EVMBlockchain) async throws {
        let fixture = try #require(liveFixture(for: chain))
        let client = makeClient(chain)
        let holder = try EthereumAddress(string: fixture.nativeHolder)

        #expect(try await client.getNativeBalance(holder) > 0)
        #expect(try await client.isActiveAccount(holder))
    }

    @Test(arguments: EVMBlockchain.presets)
    func readsTokenBalancesThroughMulticall(_ chain: EVMBlockchain) async throws {
        let fixture = try #require(liveFixture(for: chain))
        let token = try EthereumAddress(string: fixture.token)
        let balances = try await makeClient(chain).getBalances(
            try EthereumAddress(string: fixture.nativeHolder),
            tokens: [fixture.token]
        )

        #expect(balances[token.string] != nil)
    }

    @Test(arguments: EVMBlockchain.presets)
    func readsTokenInfoOfAWellKnownContract(_ chain: EVMBlockchain) async throws {
        let fixture = try #require(liveFixture(for: chain))
        let info = try await makeClient(chain).getTokenInfo(fixture.token)

        #expect(info.symbol == fixture.symbol)
        #expect(info.decimals == fixture.decimals)
        #expect(!info.isNative)
    }

    @Test(arguments: EVMBlockchain.presets)
    func reportsTheNativeTokenForNilToken(_ chain: EVMBlockchain) async throws {
        let info = try await makeClient(chain).getTokenInfo(nil)
        #expect(info.symbol == chain.nativeToken.symbol)
    }
}
