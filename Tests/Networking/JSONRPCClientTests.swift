// Tests for Sources/Static/Networking/JSONRPCClient.swift: the JSON-RPC 2.0
// envelope encode/decode, plus every ``BlockchainClientError`` case it can
// throw. Uses StubURLProtocol so these exercise the real `URLSession`
// pipeline without a real network call.

import Foundation
import Testing
@testable import WalletKit

struct JSONRPCClientTests {
    private let endpoint = URL(string: "https://example.com/rpc")!

    private func makeClient(_ stub: StubURLProtocol.Session) -> JSONRPCClient {
        JSONRPCClient(endpoint: endpoint, session: stub.urlSession)
    }

    @Test func callDecodesTheResultOnSuccess() async throws {
        let stub = StubURLProtocol.makeSession(
            response: .success(body: Data(#"{"jsonrpc":"2.0","id":1,"result":"0x2a"}"#.utf8))
        )

        let result: String = try await makeClient(stub).call(method: "eth_blockNumber", params: [String]())
        #expect(result == "0x2a")
    }

    @Test func callSendsAWellFormedJSONRPCEnvelope() async throws {
        let stub = StubURLProtocol.makeSession(
            response: .success(body: Data(#"{"jsonrpc":"2.0","id":1,"result":"ok"}"#.utf8))
        )

        let _: String = try await makeClient(stub).call(method: "eth_getBalance", params: ["0xabc", "latest"])

        let request = try #require(stub.capturedRequest)
        #expect(request.httpMethod == "POST")
        #expect(request.url == endpoint)
        #expect(request.value(forHTTPHeaderField: "Content-Type") == "application/json")

        let body = try #require(stub.capturedBody)
        let envelope = try #require(JSONSerialization.jsonObject(with: body) as? [String: Any])
        #expect(envelope["jsonrpc"] as? String == "2.0")
        #expect(envelope["id"] as? Int == 1)
        #expect(envelope["method"] as? String == "eth_getBalance")
        #expect(envelope["params"] as? [String] == ["0xabc", "latest"])
    }

    @Test func callThrowsRPCErrorOnAnErrorResponse() async throws {
        let body = #"{"jsonrpc":"2.0","id":1,"error":{"code":-32000,"message":"boom"}}"#
        let client = makeClient(StubURLProtocol.makeSession(response: .success(body: Data(body.utf8))))

        do {
            let _: String = try await client.call(method: "eth_call", params: [String]())
            Issue.record("expected call(method:params:) to throw")
        } catch let error as BlockchainClientError {
            #expect(error == .rpcError(code: -32000, message: "boom"))
        }
    }

    @Test func callThrowsInvalidResponseOnANon2xxHTTPStatus() async throws {
        let stub = StubURLProtocol.makeSession(response: .success(statusCode: 500, body: Data()))
        let client = makeClient(stub)

        await #expect(throws: BlockchainClientError.self) {
            let _: String = try await client.call(method: "eth_call", params: [String]())
        }
    }

    @Test func callThrowsInvalidResponseWhenNeitherResultNorErrorArePresent() async throws {
        let stub = StubURLProtocol.makeSession(response: .success(body: Data(#"{"jsonrpc":"2.0","id":1}"#.utf8)))
        let client = makeClient(stub)

        do {
            let _: String = try await client.call(method: "eth_call", params: [String]())
            Issue.record("expected call(method:params:) to throw")
        } catch let error as BlockchainClientError {
            #expect(error == .invalidResponse(reason: "response had neither result nor error"))
        }
    }

    @Test func callThrowsDecodingFailedWhenResultDoesNotMatchTheExpectedType() async throws {
        let stub = StubURLProtocol.makeSession(
            response: .success(body: Data(#"{"jsonrpc":"2.0","id":1,"result":42}"#.utf8))
        )

        let client = makeClient(stub)

        do {
            let _: String = try await client.call(method: "eth_call", params: [String]())
            Issue.record("expected call(method:params:) to throw")
        } catch let error as BlockchainClientError {
            guard case .decodingFailed = error else {
                Issue.record("expected .decodingFailed, got \(error)")
                return
            }
        }
    }

    @Test func callThrowsTransportErrorOnATransportFailure() async throws {
        let stub = StubURLProtocol.makeSession(response: .failure(.notConnectedToInternet))
        let client = makeClient(stub)

        do {
            let _: String = try await client.call(method: "eth_call", params: [String]())
            Issue.record("expected call(method:params:) to throw")
        } catch let error as BlockchainClientError {
            guard case .transportError = error else {
                Issue.record("expected .transportError, got \(error)")
                return
            }
        }
    }

    // MARK: - Quota feedback

    /// A client on its own origin, so a quota signal can't slow other tests' shared gate.
    private func isolatedClient(replying body: String) -> (client: JSONRPCClient, origin: String) {
        let stub = StubURLProtocol.makeSession(response: .success(body: Data(body.utf8)))
        let origin = "https://quota-\(UUID().uuidString.lowercased()).example.com"
        return (JSONRPCClient(endpoint: URL(string: "\(origin)/rpc")!, session: stub.urlSession), origin)
    }

    private func gate(_ origin: String) -> RateGate<ContinuousClock> {
        RateGateRegistry.shared.gate(for: origin, provider: .jsonRPC)
    }

    @Test func aMetadataOnlyQuotaReplyIsQuotaExceededAndSlowsTheGate() async throws {
        let data = #"{"backoff_seconds":2,"allowed_rps":5}"#
        let (client, origin) = isolatedClient(
            replying: #"{"id":1,"error":{"code":-32005,"message":"limit","data":\#(data)}}"#
        )

        do {
            let _: String = try await client.call(method: "eth_call", params: [String]())
            Issue.record("expected a throw")
        } catch let error as BlockchainClientError {
            #expect(error == .quotaExceeded(code: -32005, message: "limit", retryAfter: .seconds(2)))
            #expect(error.isQuotaExceeded)
        }

        #expect(await gate(origin).mode == .paced)
    }

    @Test func anEthGetLogsResultCapIsNotQuota() async throws {
        let message = "query returned more than 10000 results"
        let body = #"{"id":1,"error":{"code":-32005,"message":"\#(message)"}}"#
        let (client, origin) = isolatedClient(replying: body)

        do {
            let _: String = try await client.call(method: "eth_getLogs", params: [String]())
            Issue.record("expected a throw")
        } catch let error as BlockchainClientError {
            #expect(error == .rpcError(code: -32005, message: message))
        }

        #expect(await gate(origin).mode == .unpaced)
    }

    @Test func aBatchWithAQuotaErrorKeepsItsPartialResultsAndSlowsTheGate() async throws {
        let (client, origin) = isolatedClient(
            replying: #"[{"id":1,"result":"0x1"},{"id":2,"error":{"code":429,"message":"too many requests"}}]"#
        )

        let results: [String?] = try await client.callBatch(method: "eth_call", params: ["a", "b"])

        #expect(results == ["0x1", nil])
        #expect(await gate(origin).mode == .paced)
    }

    @Test func aHealthyBatchRecordsOneSuccessAndAnAllErrorBatchNone() async throws {
        let (client, origin) = isolatedClient(replying: #"[{"id":1,"result":"0x1"},{"id":2,"result":"0x2"}]"#)
        let _: [String?] = try await client.callBatch(method: "eth_call", params: ["a", "b"])
        #expect(await gate(origin).recordedSuccesses == 1)

        let (other, otherOrigin) = isolatedClient(replying: #"[{"id":1,"error":{"code":-32000,"message":"boom"}}]"#)
        let _: [String?] = try await other.callBatch(method: "eth_call", params: ["a"])
        #expect(await gate(otherOrigin).recordedSuccesses == 0)
    }
}
