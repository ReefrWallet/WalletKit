// Tests for Sources/WalletKit/Blockchains/Solana/SolanaRPCClient.swift's
// `sendTransaction(_:options:)`. Uses `StubURLProtocol` exactly like
// `JSONRPCClientTests`/`EthereumRPCClientTests` — exercises the real
// `URLSession`/Moya pipeline without a real network call.

import Foundation
import Testing
@testable import WalletKit

struct SolanaRPCClientTests {
    private func address(_ byte: UInt8) throws -> SolanaAddress {
        try SolanaAddress(rawBytes: Data(repeating: byte, count: 32))
    }

    /// A real legacy `Message`, wrapped into a complete wire transaction
    /// with one known 64-byte signature — the same fixture shape
    /// `SolanaWireTransactionTests` uses.
    private func wireTransaction(signature: Data) throws -> Data {
        let payer = try address(1)
        let recipient = try address(2)
        let message = try SolanaMessage.compile(
            payer: payer,
            instructions: [SystemProgram.transfer(from: payer, to: recipient, lamports: 1_000)],
            recentBlockhash: Data(repeating: 9, count: 32)
        )

        var tx = SolanaShortVec.encode(1)
        tx.append(signature)
        tx.append(message.serialize())
        return tx
    }

    private func makeClient(_ stub: StubURLProtocol.Session) -> SolanaRPCClient {
        SolanaRPCClient(endpoint: URL(string: "https://example.com/rpc")!, session: stub.urlSession)
    }

    @Test func sendTransactionReturnsTheNodesSignatureOnSuccess() async throws {
        let signature = Data(repeating: 0xAB, count: 64)
        let stub = StubURLProtocol.makeSession(
            response: .success(body: Data(#"{"jsonrpc":"2.0","id":1,"result":"node-reported-signature"}"#.utf8))
        )

        let result = try await makeClient(stub).sendTransaction(try wireTransaction(signature: signature))
        #expect(result == "node-reported-signature")
    }

    /// Covers the ambiguous-retry case: a 429/503 retry can land on
    /// "already been processed" even though the first attempt landed.
    /// Solana has no separate transaction hash — the signature is the
    /// identifier, and it's already embedded in the wire transaction sent,
    /// so it's recovered locally instead of surfacing a false failure.
    @Test func sendTransactionRecoversTheSignatureLocallyWhenAlreadyProcessed() async throws {
        let signature = Data(repeating: 0xCD, count: 64)
        let body = #"""
        {"jsonrpc":"2.0","id":1,"error":{"code":-32002,"message":"This transaction has already been processed"}}
        """#
        let stub = StubURLProtocol.makeSession(response: .success(body: Data(body.utf8)))

        let result = try await makeClient(stub).sendTransaction(try wireTransaction(signature: signature))
        #expect(result == Base58.encode(signature))
    }

    @Test func sendTransactionThrowsRPCErrorForAnUnrelatedFailure() async throws {
        let body = #"{"jsonrpc":"2.0","id":1,"error":{"code":-32602,"message":"invalid params"}}"#
        let client = makeClient(StubURLProtocol.makeSession(response: .success(body: Data(body.utf8))))

        do {
            _ = try await client.sendTransaction(try wireTransaction(signature: Data(repeating: 0xEF, count: 64)))
            Issue.record("expected sendTransaction(_:options:) to throw")
        } catch let error as BlockchainClientError {
            #expect(error == .rpcError(code: -32602, message: "invalid params"))
        }
    }
}
