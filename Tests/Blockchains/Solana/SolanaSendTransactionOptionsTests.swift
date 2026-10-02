// Tests for SolanaRPCClient.sendTransaction(_:options:) — the request's
// JSON shape and the post-broadcast confirmation-polling wait. Uses
// StubURLProtocol so these exercise the real URLSession/JSONRPCClient
// pipeline without a real Solana RPC node.

import Foundation
import Testing
@testable import WalletKit

// `.serialized`: several tests mutate `SolanaRPCClient.confirmationTimeout`/
// `.confirmationPollInterval` (internal test seams, not per-instance state)
// for the duration of one test — running concurrently with another test in
// this suite would race those shared statics.
@Suite(.serialized)
struct SolanaSendTransactionOptionsTests {
    private let endpoint = URL(string: "https://example.com/rpc")!

    private func configDict(from body: Data) throws -> [String: Any] {
        let envelope = try #require(JSONSerialization.jsonObject(with: body) as? [String: Any])
        let params = try #require(envelope["params"] as? [Any])
        return try #require(params.last as? [String: Any])
    }

    @Test func defaultOptionsOmitUnsetFieldsAndDefaultPreflightCommitmentToConfirmed() async throws {
        let stub = StubURLProtocol.makeSession(
            response: .success(body: Data(#"{"jsonrpc":"2.0","id":1,"result":"sig"}"#.utf8))
        )
        let client = SolanaRPCClient(endpoint: endpoint, session: stub.urlSession)

        _ = try await client.sendTransaction(Data([0x01]))

        let config = try configDict(from: try #require(stub.capturedBody))
        #expect(config["encoding"] as? String == "base64")
        #expect(config["preflightCommitment"] as? String == "confirmed")
        #expect(config["skipPreflight"] == nil)
        #expect(config["maxRetries"] == nil)
        #expect(config["minContextSlot"] == nil)
    }

    @Test func everyPresentOptionIsEncoded() async throws {
        let stub = StubURLProtocol.makeSession(
            response: .success(body: Data(#"{"jsonrpc":"2.0","id":1,"result":"sig"}"#.utf8))
        )
        let client = SolanaRPCClient(endpoint: endpoint, session: stub.urlSession)

        _ = try await client.sendTransaction(
            Data([0x01]),
            options: SolanaSendTransactionOptions(
                maxRetries: 5, minContextSlot: 1_000, preflightCommitment: .finalized, skipPreflight: true
            )
        )

        let config = try configDict(from: try #require(stub.capturedBody))
        #expect(config["preflightCommitment"] as? String == "finalized")
        #expect(config["skipPreflight"] as? Bool == true)
        #expect(config["maxRetries"] as? Int == 5)
        #expect(config["minContextSlot"] as? Int == 1_000)
    }

    @Test func confirmationSucceedsOncePolledStatusReachesTheRequestedCommitment() async throws {
        SolanaRPCClient.confirmationPollInterval = 1_000_000 // 1ms, for a fast test
        defer { SolanaRPCClient.confirmationPollInterval = 1_000_000_000 }

        let stub = StubURLProtocol.makeSession(responseSequence: [
            .success(body: Data(#"{"jsonrpc":"2.0","id":1,"result":"sig123"}"#.utf8)),
            .success(body: Data(#"{"jsonrpc":"2.0","id":1,"result":{"value":[null]}}"#.utf8)),
            .success(body: Data(#"{"jsonrpc":"2.0","id":1,"result":{"value":[{"confirmationStatus":"confirmed","err":null}]}}"#.utf8))
        ])
        let client = SolanaRPCClient(endpoint: endpoint, session: stub.urlSession)

        let signature = try await client.sendTransaction(
            Data([0x01]), options: SolanaSendTransactionOptions(commitment: .confirmed)
        )
        #expect(signature == "sig123")
    }

    @Test func confirmationSucceedsWhenThePolledStatusExceedsTheRequestedCommitment() async throws {
        // Requesting `confirmed` but the cluster already reports
        // `finalized` (a stricter commitment) must still satisfy the wait.
        let stub = StubURLProtocol.makeSession(responseSequence: [
            .success(body: Data(#"{"jsonrpc":"2.0","id":1,"result":"sig123"}"#.utf8)),
            .success(body: Data(#"{"jsonrpc":"2.0","id":1,"result":{"value":[{"confirmationStatus":"finalized","err":null}]}}"#.utf8))
        ])
        let client = SolanaRPCClient(endpoint: endpoint, session: stub.urlSession)

        let signature = try await client.sendTransaction(
            Data([0x01]), options: SolanaSendTransactionOptions(commitment: .confirmed)
        )
        #expect(signature == "sig123")
    }

    @Test func confirmationThrowsWhenTheTransactionFailsOnChain() async throws {
        let stub = StubURLProtocol.makeSession(responseSequence: [
            .success(body: Data(#"{"jsonrpc":"2.0","id":1,"result":"sig123"}"#.utf8)),
            .success(body: Data(
                #"{"jsonrpc":"2.0","id":1,"result":{"value":[{"confirmationStatus":"processed","err":{"InstructionError":[0,"Custom"]}}]}}"#.utf8
            ))
        ])
        let client = SolanaRPCClient(endpoint: endpoint, session: stub.urlSession)

        await #expect(throws: BlockchainClientError.self) {
            _ = try await client.sendTransaction(Data([0x01]), options: SolanaSendTransactionOptions(commitment: .confirmed))
        }
    }

    @Test func confirmationTimesOutIfTheCommitmentIsNeverReached() async throws {
        SolanaRPCClient.confirmationTimeout = 0.02
        SolanaRPCClient.confirmationPollInterval = 5_000_000 // 5ms
        defer {
            SolanaRPCClient.confirmationTimeout = 30
            SolanaRPCClient.confirmationPollInterval = 1_000_000_000
        }

        let stub = StubURLProtocol.makeSession(responseSequence: [
            .success(body: Data(#"{"jsonrpc":"2.0","id":1,"result":"sig123"}"#.utf8)),
            .success(body: Data(#"{"jsonrpc":"2.0","id":1,"result":{"value":[null]}}"#.utf8))
        ])
        let client = SolanaRPCClient(endpoint: endpoint, session: stub.urlSession)

        await #expect(throws: BlockchainClientError.self) {
            _ = try await client.sendTransaction(Data([0x01]), options: SolanaSendTransactionOptions(commitment: .confirmed))
        }
    }

    @Test func noConfirmationWaitWhenNoCommitmentIsRequested() async throws {
        // Only one response queued — if this polled at all, it would
        // exhaust the sequence and keep reusing it harmlessly, but the
        // point of this test is that it doesn't poll: a second, unwanted
        // request would still hit the same stub, so this mainly guards
        // against a regression that starts confirming unconditionally.
        let stub = StubURLProtocol.makeSession(
            response: .success(body: Data(#"{"jsonrpc":"2.0","id":1,"result":"sig123"}"#.utf8))
        )
        let client = SolanaRPCClient(endpoint: endpoint, session: stub.urlSession)

        let signature = try await client.sendTransaction(Data([0x01]))
        #expect(signature == "sig123")
    }
}
