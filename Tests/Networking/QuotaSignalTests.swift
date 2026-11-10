import Foundation
import Testing
@testable import WalletKit

struct QuotaSignalTests {
    @Test func recognizesVerifiedQuotaReplies() {
        let replies: [(Int, String)] = [
            (-32005, "daily request count exceeded, request rate limited"), // Infura
            (429, "Your app has exceeded its compute units per second capacity"), // Alchemy
            (-32007, "50/second request limit reached - reduce calls per second"), // QuickNode
            (429, "")
        ]

        for (code, message) in replies {
            #expect(QuotaSignal.detect(code: code, message: message, data: nil) != nil, "\(message)")
        }
    }

    @Test func infuraResultCapsAndTimeoutsAreNotQuota() {
        let replies = [
            "query returned more than 10000 results. Try with this block range [0x1, 0x2].",
            "query timeout exceeded"
        ]

        for message in replies {
            #expect(QuotaSignal.detect(code: -32005, message: message, data: nil) == nil, "\(message)")
        }
    }

    @Test func aQuotaCodeAloneNeedsMetadata() {
        #expect(QuotaSignal.detect(code: -32005, message: "limit", data: nil) == nil)

        let signal = QuotaSignal.detect(
            code: -32005,
            message: "limit",
            data: ["backoff_seconds": 2.0, "allowed_rps": 5.0]
        )

        #expect(signal?.retryAfter == .seconds(2))
    }

    @Test func quotaErrorsAreRecognizedAcrossTheErrorBoundary() {
        let error = BlockchainClientError.quotaExceeded(code: -32005, message: "limit", retryAfter: nil)
        #expect(error.isQuotaExceeded)
        #expect(!BlockchainClientError.rpcError(code: -32000, message: "boom").isQuotaExceeded)
    }
}
