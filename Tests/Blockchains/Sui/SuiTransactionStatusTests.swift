// A lookup result is only an answer when it is the transaction asked for,
// checkpointed, with an explicit execution status.

import Foundation
import Testing
@testable import WalletKit
import WalletKitGRPC

struct SuiTransactionStatusTests {
    private func transaction(
        digest: String = "D", checkpoint: Bool = true, status: Sui_Rpc_V2_ExecutionStatus?
    ) -> Sui_Rpc_V2_ExecutedTransaction {
        Sui_Rpc_V2_ExecutedTransaction.with {
            $0.digest = digest
            if checkpoint {
                $0.checkpoint = 9
            }

            if let status {
                $0.effects = Sui_Rpc_V2_TransactionEffects.with { $0.status = status }
            }
        }
    }

    private func status(success: Bool?, error: String? = nil) -> Sui_Rpc_V2_ExecutionStatus {
        Sui_Rpc_V2_ExecutionStatus.with {
            if let success {
                $0.success = success
            }

            if let error {
                $0.error = Sui_Rpc_V2_ExecutionError.with { $0.description_p = error }
            }
        }
    }

    @Test
    func anExplicitSuccessAndAnExplicitFailureAreBothAnswers() throws {
        let ok = try SuiGRPCClient.finalizedStatus(of: transaction(status: status(success: true)), expectedDigest: "D")
        #expect(ok == .finalized(failure: nil))

        let failed = try SuiGRPCClient.finalizedStatus(
            of: transaction(status: status(success: false, error: "MoveAbort")), expectedDigest: "D"
        )
        #expect(failed == .finalized(failure: "MoveAbort"))
    }

    @Test
    func anOmittedSuccessIsNotReadAsAFailure() {
        #expect(throws: BlockchainClientError.self) {
            try SuiGRPCClient.finalizedStatus(of: transaction(status: status(success: nil)), expectedDigest: "D")
        }
    }

    @Test
    func missingEffectsOrStatusIsNotAnAnswer() {
        #expect(throws: BlockchainClientError.self) {
            try SuiGRPCClient.finalizedStatus(of: transaction(status: nil), expectedDigest: "D")
        }

        let noStatus = Sui_Rpc_V2_ExecutedTransaction.with {
            $0.digest = "D"
            $0.checkpoint = 9
            $0.effects = Sui_Rpc_V2_TransactionEffects()
        }
        #expect(throws: BlockchainClientError.self) {
            try SuiGRPCClient.finalizedStatus(of: noStatus, expectedDigest: "D")
        }
    }

    @Test
    func aDifferentDigestIsNotAnAnswer() {
        #expect(throws: BlockchainClientError.self) {
            let other = transaction(digest: "X", status: status(success: true))
            _ = try SuiGRPCClient.finalizedStatus(of: other, expectedDigest: "D")
        }
    }

    @Test
    func aTransactionNotYetInACheckpointIsNotAnAnswer() {
        #expect(throws: BlockchainClientError.self) {
            try SuiGRPCClient.finalizedStatus(
                of: transaction(checkpoint: false, status: status(success: true)), expectedDigest: "D"
            )
        }
    }
}
