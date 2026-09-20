// Integration tests for
// Sources/Static/Blockchains/Sui/SuiGRPCClient.swift, against Sui's public
// testnet gRPC full node (fullnode.testnet.sui.io:443).
//
// Unlike EthereumRPCClientTests, these can't be mocked out: `SuiGRPCClient`
// builds its own `HTTP2ClientTransport.Posix` internally with no injection
// seam, and `make sui-grpc` generates gRPC *client* stubs only
// (`Server=false` — see WalletKit/Makefile), so there's no generated
// in-process fake server to stand up either. Real testnet access is
// therefore the only way to exercise the request/response wire path, in
// line with Docs/Overview.md's "Testable against pre-configured test
// wallets on testnet for every supported blockchain" testing-strategy goal.
//
// `withKnownIssue(isIntermittent: true)` keeps a lack of network access
// (sandboxed CI, offline dev) from failing these — the same accommodation
// EthereumTrezorSignerTests makes for "requires a connected hardware
// wallet, unavailable in CI". `isIntermittent` (vs. the hardware tests'
// plain `withKnownIssue`) matters here specifically because these are
// normally expected to succeed whenever the network is up, so a plain
// `withKnownIssue` would itself flag "no known issue occurred" on every
// green run.

import Foundation
import Testing
@testable import WalletKit

// Sui's framework system package — a stable, permanent address, queryable
// on every network without needing a funded test wallet. Its actual SUI
// balance isn't asserted on below: unlike a plain unused account (which
// would deterministically hold zero), Sui's protocol-level bookkeeping
// around this address isn't something to assume a specific value for from
// first principles — the point here is exercising a real, successful
// request/response round trip, not verifying chain state.
// swiftlint:disable:next force_try
private let systemPackageAddress = try! SuiAddress(
    string: "0x0000000000000000000000000000000000000000000000000000000000000002"
)

// Circle's official native-USDC coin type on Sui testnet — a stable,
// well-known coin whose metadata (name, symbol, decimals) is known ahead of
// time, unlike an arbitrary coin type.
private let usdcCoinType = "0xa1ec7fc00a6f40db9693ad1415d0c193ad3906494428cf252621037bd7117e29::usdc::USDC"

@Suite(.timeLimit(.minutes(1)))
struct SuiGRPCClientTests {
    private let client = SuiGRPCClient(host: "fullnode.testnet.sui.io")

    @Test func nativeBalanceSucceedsAgainstTheLiveTestnet() async throws {
        await withKnownIssue("requires network access to Sui's testnet gRPC full node", isIntermittent: true) {
            _ = try await client.nativeBalance(of: systemPackageAddress)
        }
    }

    @Test func coinInfoFetchesUSDCsMetadataFromTheLiveTestnet() async throws {
        await withKnownIssue("requires network access to Sui's testnet gRPC full node", isIntermittent: true) {
            let info = try await client.coinInfo(coinType: usdcCoinType)
            #expect(info.name == "USDC")
            #expect(info.symbol == "USDC")
            #expect(info.decimals == 6)
        }
    }

    @Test func broadcastOfAMalformedTransactionSurfacesAsAnRPCErrorFromTheLiveTestnet() async throws {
        await withKnownIssue("requires network access to Sui's testnet gRPC full node", isIntermittent: true) {
            do {
                // Two garbage bytes are neither valid BCS `TransactionData`
                // nor a valid signature — no real node can execute this, and
                // no funds are at risk since it's rejected before execution.
                _ = try await client.broadcast(transactionData: Data([0xFF, 0xFF]), signature: Data([0xFF, 0xFF]))
                Issue.record("expected the node to reject a malformed transaction")
            } catch let error as BlockchainClientError {
                guard case .rpcError = error else {
                    Issue.record("expected .rpcError, got \(error)")
                    return
                }
            }
        }
    }

    @Test func aNonExistentHostFailsToConnect() async throws {
        // grpc-swift-nio-transport resolves and connects lazily, and wraps
        // the DNS failure as an `RPCError` (status `.unavailable`) itself
        // rather than letting a raw connection error surface — so this
        // comes back as `.rpcError`, not `.transportError` (reserved for
        // failures in constructing the transport itself, before any
        // connection attempt). Fully hermetic: DNS failure for a
        // `.invalid`-TLD host (reserved by RFC 2606 to never resolve) is
        // fast and doesn't depend on real network access.
        let client = SuiGRPCClient(host: "this-host-does-not-exist.invalid")
        do {
            _ = try await client.nativeBalance(of: systemPackageAddress)
            Issue.record("expected nativeBalance(of:) to throw")
        } catch let error as BlockchainClientError {
            guard case .rpcError = error else {
                Issue.record("expected .rpcError, got \(error)")
                return
            }
        }
    }
}
