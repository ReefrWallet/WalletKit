// Integration tests for `SuiGRPCClient.cetusPoolPrice(pool:token:)` —
// against Sui's public *mainnet* gRPC full node (fullnode.mainnet.sui.io),
// unlike SuiGRPCClientTests' testnet default: Cetus's real, liquid pools
// only exist on mainnet. Same "no injection seam" situation as
// SuiGRPCClientTests (see that file's header), so this is a live-network
// test wrapped in `withKnownIssue(isIntermittent: true)`.
//
// The pool used below — USDC/SUI, 0.25% fee tier — was confirmed live via
// `grpcurl` against `sui.rpc.v2.LedgerService/GetObject` while writing this
// client: its `object_type` is `<pkg>::pool::Pool<<USDC>, <SUI>>` and its
// `json.current_sqrt_price` decodes to a plausible, real SUI/USDC price,
// so this is exercising real Cetus pool data, not a guessed shape.

import Foundation
import Testing
@testable import WalletKit

// Cetus's highest-liquidity USDC/SUI pool on mainnet (0.25% fee tier).
private let cetusUSDCSUIPool = "0xb8d7d9e66a60c239e7a60110efcf8de6c705580ed924d0dde141f4a0e2c90105"

// Circle's native mainnet USDC coin type (distinct from the older,
// Wormhole-bridged USDC).
private let usdcMainnetCoinType = "0xdba34672e30cb065b1f93e3ab55318768fd6fef66c15942c9f7cb846e2f900e7::usdc::USDC"

@Suite(.timeLimit(.minutes(1)))
struct SuiCetusTests {
    private let client = SuiGRPCClient(host: "fullnode.mainnet.sui.io")

    @Test func cetusPoolPriceOfSUIAndUSDCAreConsistentReciprocalsInARealisticRange() async throws {
        await withKnownIssue("requires network access to Sui's mainnet gRPC full node", isIntermittent: true) {
            let suiInUSDC = try await client.cetusPoolPrice(pool: cetusUSDCSUIPool, token: "0x2::sui::SUI")
            let usdcInSUI = try await client.cetusPoolPrice(pool: cetusUSDCSUIPool, token: usdcMainnetCoinType)

            // Broad bounds — only meant to catch a gross unit/decimal
            // error (which would be off by many orders of magnitude), not
            // to track SUI's actual price.
            #expect(suiInUSDC > 0.01 && suiInUSDC < 1_000, "SUI/USDC price \(suiInUSDC) is outside a realistic range")

            // The two directions are exact reciprocals of one another.
            #expect(abs(suiInUSDC * usdcInSUI - 1) < 0.001)
        }
    }

    @Test func cetusPoolPriceThrowsWhenTokenIsNeitherOfThePoolsCoinTypes() async throws {
        await withKnownIssue("requires network access to Sui's mainnet gRPC full node", isIntermittent: true) {
            // Cetus's own governance token — not part of the USDC/SUI pool.
            let unrelatedCoinType = "0x06864a6f921804860930db6ddbe2e16acdf8504495ea7481637a1c8b9a8fe54b::cetus::CETUS"

            await #expect(throws: BlockchainClientError.self) {
                _ = try await client.cetusPoolPrice(pool: cetusUSDCSUIPool, token: unrelatedCoinType)
            }
        }
    }
}
