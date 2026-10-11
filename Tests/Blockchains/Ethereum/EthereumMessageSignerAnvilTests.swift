// Integration tests for EthereumPKeySigner's MessageSigner conformance
// (personal_sign/eth_signTypedData_v4) against a real, running local
// Ethereum node (Foundry's `anvil`). Mirrors EthereumAnvilTests.swift's
// "real infrastructure, not a mock" philosophy — but the interesting
// property to check isn't hash correctness (that's already covered by
// walletkit-ffi's Rust vectors against the EIP-191 formula and the
// EIP-712 spec's own "Mail" example), it's that the *signature* is one a
// wallet's counterparty would actually accept: recovered back to the
// signer's own address.
//
// Anvil holds its own default dev accounts' private keys in-memory and
// implements `personal_sign`/`eth_signTypedData_v4` for them directly, so
// asking it to sign the exact same message with the exact same
// (well-known) private key is an address-recovery check without adding
// any new recovery API to WalletKit: both ECDSA signers use RFC6979
// deterministic nonces, so two correct implementations signing the same
// digest with the same key must produce byte-identical signatures.

import BigInt
import Foundation
import Testing
import WalletKit
import WalletKitTesting

private extension Data {
    var hexEncoded: String { "0x" + map { String(format: "%02x", $0) }.joined() }
}

/// Anvil's own well-known default account #0 — see
/// EthereumAnvilTests.swift's identical constant for provenance.
private let anvilDefaultAccountPrivateKeyHex = "0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80"

private func makeAnvilDefaultSigner(chainId: UInt64) throws -> EthereumPKeySigner {
    let hex = anvilDefaultAccountPrivateKeyHex.hasPrefix("0x")
        ? String(anvilDefaultAccountPrivateKeyHex.dropFirst(2))
        : anvilDefaultAccountPrivateKeyHex
    var data = Data(capacity: hex.count / 2)
    var index = hex.startIndex
    while index < hex.endIndex {
        let next = hex.index(index, offsetBy: 2, limitedBy: hex.endIndex) ?? hex.endIndex
        data.append(UInt8(hex[index..<next], radix: 16)!)
        index = next
    }

    let privateKey = try PrivateKey(curve: .secp256k1, rawBytes: data)
    return try EthereumPKeySigner(
        chainId: chainId,
        privateKey: privateKey,
        derivationPath: TestAccountFactory.bip44Path(coinType: 60)
    )
}

@Suite(.timeLimit(.minutes(1)), .localNode)
struct EthereumMessageSignerAnvilTests {
    @Test func personalSignMatchesAnvilsOwnSignatureForTheSameKeyAndMessage() async throws {
        let node = try await EthereumNode.start()
        defer { node.stop() }

        let signer = try makeAnvilDefaultSigner(chainId: node.chainId)
        let address = try signer.address()
        let message = Data("Example personal_sign message".utf8)

        let signature = try await signer.sign(message: .ethereumPersonal(message))
        #expect(signature.count == 65)

        let client = EthereumRPCClient(endpoint: node.endpoint, chainId: node.chainId)
        let paramsJSON = try JSONEncoder().encode([message.hexEncoded, address.string])
        let rawResult = try await client.request(method: "personal_sign", params: paramsJSON)
        let anvilSignatureHex = try JSONDecoder().decode(String.self, from: rawResult)

        #expect(signature.hexEncoded == anvilSignatureHex)
    }

    @Test func typedDataSignatureMatchesAnvilsOwnSignatureForTheSameKeyAndPayload() async throws {
        let node = try await EthereumNode.start()
        defer { node.stop() }

        let signer = try makeAnvilDefaultSigner(chainId: node.chainId)
        let address = try signer.address()
        let json = """
        {
            "types": {
                "EIP712Domain": [
                    {"name": "name", "type": "string"},
                    {"name": "version", "type": "string"},
                    {"name": "chainId", "type": "uint256"},
                    {"name": "verifyingContract", "type": "address"}
                ],
                "Person": [
                    {"name": "name", "type": "string"},
                    {"name": "wallet", "type": "address"}
                ],
                "Mail": [
                    {"name": "from", "type": "Person"},
                    {"name": "to", "type": "Person"},
                    {"name": "contents", "type": "string"}
                ]
            },
            "primaryType": "Mail",
            "domain": {
                "name": "Ether Mail",
                "version": "1",
                "chainId": 1,
                "verifyingContract": "0xCcCCccccCCCCcCCCCCCcCcCccCcCCCcCcccccccC"
            },
            "message": {
                "from": {"name": "Cow", "wallet": "0xCD2a3d9F938E13CD947Ec05AbC7FE734Df8DD826"},
                "to": {"name": "Bob", "wallet": "0xbBbBBBBbbBBBbbbBbbBbbbbBBbBbbbbBbBbbBBbB"},
                "contents": "Hello, Bob!"
            }
        }
        """

        let signature = try await signer.sign(message: .ethereumTypedData(json: json))
        #expect(signature.count == 65)

        let client = EthereumRPCClient(endpoint: node.endpoint, chainId: node.chainId)
        let payload = try #require(JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
        let paramsJSON = try JSONSerialization.data(withJSONObject: [address.string, payload])
        let rawResult = try await client.request(method: "eth_signTypedData_v4", params: paramsJSON)
        let anvilSignatureHex = try JSONDecoder().decode(String.self, from: rawResult)

        #expect(signature.hexEncoded == anvilSignatureHex)
    }

    @Test func requestPassesThroughAnArbitraryReadOnlyMethodAgainstALiveNode() async throws {
        let node = try await EthereumNode.start()
        defer { node.stop() }

        let client = EthereumRPCClient(endpoint: node.endpoint, chainId: node.chainId)
        let rawResult = try await client.request(method: "eth_blockNumber", params: Data("[]".utf8))
        let blockNumberHex = try JSONDecoder().decode(String.self, from: rawResult)

        #expect(blockNumberHex.hasPrefix("0x"))
        #expect(BigUInt(blockNumberHex.dropFirst(2), radix: 16) != nil)
    }
}
