// Integration tests for EthereumTransactionBuilder against a real,
// running local Ethereum node (Foundry's `anvil`). Mirrors
// EthereumAnvilTests.swift's "real infrastructure, not a mock" philosophy:
// derive a wallet, fund it, use the builder to produce unsigned bytes, sign
// them with EthereumPKeySigner, broadcast, and confirm the chain's own state
// changed by exactly the expected amount.
//
// Both the EIP-155 legacy path (options: [.legacyEip155]) and the default
// EIP-1559 type-2 path (options: []) are exercised for native ETH and
// ERC-20 transfers.
//
// `anvil` is run via `mise x foundry -- anvil` (AnvilNode.swift). There's
// no `withKnownIssue` gating: if the node can't start, the suite fails
// loudly.

import BigInt
import Foundation
import Testing
import WalletKit
import WalletKitTesting

@Suite(.timeLimit(.minutes(1)))
struct EthereumTransactionBuilderTests {
    // MARK: - Native ETH transfer (EIP-155 legacy)

    @Test func builderProducesValidNativeETHTransferThatDecrementsSenderBalance() async throws {
        let node = try await AnvilNode.start()
        defer { node.stop() }

        let vectors = loadEthAddressVectors()
        let signerA = try makeEthSigner(privateKeyHex: vectors[0].privateKey, chainId: node.chainId)
        let walletA = try signerA.address()
        let walletB = try EthereumAddress(string: vectors[1].address)

        let oneEther = BigUInt(1_000_000_000_000_000_000)
        try await node.setBalance(walletA, wei: oneEther * 10)
        try await node.setBalance(walletB, wei: oneEther * 10)

        let client = EthereumRPCClient(endpoint: node.endpoint, chainId: node.chainId)
        let builder = EthereumTransactionBuilder(client: client)

        let beforeA = try await client.nativeBalance(of: walletA)
        let beforeB = try await client.nativeBalance(of: walletB)

        let txBytes = try await builder.buildTransfer(
            sender: walletA, recipient: walletB, amount: oneEther, token: nil,
            options: [.legacyEip155]
        )
        let signed = try await signerA.sign(transaction: txBytes)
        let hash = try await client.broadcast(signed)
        #expect(!hash.isEmpty)

        let receipt = try await node.waitForReceipt(hash)
        #expect(receipt.status == "0x1", "native ETH transfer should succeed")

        let afterA = try await client.nativeBalance(of: walletA)
        let afterB = try await client.nativeBalance(of: walletB)
        #expect(afterB == beforeB + oneEther)

        // A paid the transfer amount plus gas; just verify the direction.
        #expect(afterA < beforeA - oneEther, "sender balance should drop by more than the transfer amount (gas)")
    }

    // MARK: - Native ETH transfer (EIP-1559)

    @Test func builderProducesValidEIP1559NativeETHTransferThatDecrementsSenderBalance() async throws {
        let node = try await AnvilNode.start()
        defer { node.stop() }

        let vectors = loadEthAddressVectors()
        let signerA = try makeEthSigner(privateKeyHex: vectors[0].privateKey, chainId: node.chainId)
        let walletA = try signerA.address()
        let walletB = try EthereumAddress(string: vectors[1].address)

        let oneEther = BigUInt(1_000_000_000_000_000_000)
        try await node.setBalance(walletA, wei: oneEther * 10)
        try await node.setBalance(walletB, wei: oneEther * 10)

        let client = EthereumRPCClient(endpoint: node.endpoint, chainId: node.chainId)
        let builder = EthereumTransactionBuilder(client: client)

        let beforeA = try await client.nativeBalance(of: walletA)
        let beforeB = try await client.nativeBalance(of: walletB)

        // Default options = EIP-1559 (no .legacyEip155 flag).
        let txBytes = try await builder.buildTransfer(
            sender: walletA, recipient: walletB, amount: oneEther, token: nil
        )
        let signed = try await signerA.sign(transaction: txBytes)
        let hash = try await client.broadcast(signed)
        #expect(!hash.isEmpty)

        let receipt = try await node.waitForReceipt(hash)
        #expect(receipt.status == "0x1", "EIP-1559 native ETH transfer should succeed")

        let afterA = try await client.nativeBalance(of: walletA)
        let afterB = try await client.nativeBalance(of: walletB)
        #expect(afterB == beforeB + oneEther)
        #expect(afterA < beforeA - oneEther, "sender balance should drop by more than the transfer amount (gas)")
    }

    // MARK: - ERC-20 transfer (EIP-155 legacy)

    @Test func builderProducesValidERC20TransferThatMovesTokenBalance() async throws {
        let node = try await AnvilNode.start()
        defer { node.stop() }

        let vectors = loadEthAddressVectors()
        let signerA = try makeEthSigner(privateKeyHex: vectors[0].privateKey, chainId: node.chainId)
        let deployerSigner = try makeEthSigner(
            privateKeyHex: anvilDefaultAccountPrivateKeyHex,
            chainId: node.chainId
        )
        let walletA = try signerA.address()
        let walletB = try EthereumAddress(string: vectors[1].address)

        let oneEther = BigUInt(1_000_000_000_000_000_000)
        try await node.setBalance(walletA, wei: oneEther * 10)

        let client = EthereumRPCClient(endpoint: node.endpoint, chainId: node.chainId)
        let gasPrice = try await node.gasPrice()

        // Deploy mock USDC and mint to walletA.
        let deployReceipt = try await sendRaw(
            signer: deployerSigner, to: nil, value: 0, data: mockUSDCCreationBytecode, gasLimit: 1_000_000,
            node: node, client: client, gasPrice: gasPrice
        )
        let mockUSDC = try EthereumAddress(string: try #require(deployReceipt.contractAddress))

        let mintAmount = BigUInt(1_000_000_000) // 1 000 USDC (6 decimals)
        _ = try await sendRaw(
            signer: deployerSigner,
            to: mockUSDC,
            value: 0,
            data: EthereumABI.encodeCall(
                selector: EthereumABI.selector("mint(address,uint256)"),
                parameters: [.address(walletA), .uint256(mintAmount)]
            ),
            gasLimit: 100_000,
            node: node, client: client, gasPrice: gasPrice
        )

        let beforeAUSDC = try await client.erc20Balance(token: mockUSDC, owner: walletA)
        let beforeBUSDC = try await client.erc20Balance(token: mockUSDC, owner: walletB)

        // Use the builder to produce the transfer bytes.
        let builder = EthereumTransactionBuilder(client: client)
        let transferAmount = BigUInt(100_000_000) // 100 USDC
        let txBytes = try await builder.buildTransfer(
            sender: walletA, recipient: walletB, amount: transferAmount, token: mockUSDC.string,
            options: [.legacyEip155]
        )
        let signed = try await signerA.sign(transaction: txBytes)
        let hash = try await client.broadcast(signed)
        let receipt = try await node.waitForReceipt(hash)
        #expect(receipt.status == "0x1", "ERC-20 transfer should succeed")

        let afterAUSDC = try await client.erc20Balance(token: mockUSDC, owner: walletA)
        let afterBUSDC = try await client.erc20Balance(token: mockUSDC, owner: walletB)
        #expect(afterAUSDC == beforeAUSDC - transferAmount)
        #expect(afterBUSDC == beforeBUSDC + transferAmount)
    }

    // MARK: - ERC-20 transfer (EIP-1559)

    @Test func builderProducesValidEIP1559ERC20TransferThatMovesTokenBalance() async throws {
        let node = try await AnvilNode.start()
        defer { node.stop() }

        let vectors = loadEthAddressVectors()
        let signerA = try makeEthSigner(privateKeyHex: vectors[0].privateKey, chainId: node.chainId)
        let deployerSigner = try makeEthSigner(
            privateKeyHex: anvilDefaultAccountPrivateKeyHex,
            chainId: node.chainId
        )
        let walletA = try signerA.address()
        let walletB = try EthereumAddress(string: vectors[1].address)

        let oneEther = BigUInt(1_000_000_000_000_000_000)
        try await node.setBalance(walletA, wei: oneEther * 10)

        let client = EthereumRPCClient(endpoint: node.endpoint, chainId: node.chainId)
        let gasPrice = try await node.gasPrice()

        // Deploy mock USDC and mint to walletA (setup uses legacy txs).
        let deployReceipt = try await sendRaw(
            signer: deployerSigner, to: nil, value: 0, data: mockUSDCCreationBytecode, gasLimit: 1_000_000,
            node: node, client: client, gasPrice: gasPrice
        )
        let mockUSDC = try EthereumAddress(string: try #require(deployReceipt.contractAddress))

        let mintAmount = BigUInt(1_000_000_000)
        _ = try await sendRaw(
            signer: deployerSigner,
            to: mockUSDC,
            value: 0,
            data: EthereumABI.encodeCall(
                selector: EthereumABI.selector("mint(address,uint256)"),
                parameters: [.address(walletA), .uint256(mintAmount)]
            ),
            gasLimit: 100_000,
            node: node, client: client, gasPrice: gasPrice
        )

        let beforeAUSDC = try await client.erc20Balance(token: mockUSDC, owner: walletA)
        let beforeBUSDC = try await client.erc20Balance(token: mockUSDC, owner: walletB)

        // Default options = EIP-1559.
        let builder = EthereumTransactionBuilder(client: client)
        let transferAmount = BigUInt(100_000_000)
        let txBytes = try await builder.buildTransfer(
            sender: walletA, recipient: walletB, amount: transferAmount, token: mockUSDC.string
        )
        let signed = try await signerA.sign(transaction: txBytes)
        let hash = try await client.broadcast(signed)
        let receipt = try await node.waitForReceipt(hash)
        #expect(receipt.status == "0x1", "EIP-1559 ERC-20 transfer should succeed")

        let afterAUSDC = try await client.erc20Balance(token: mockUSDC, owner: walletA)
        let afterBUSDC = try await client.erc20Balance(token: mockUSDC, owner: walletB)
        #expect(afterAUSDC == beforeAUSDC - transferAmount)
        #expect(afterBUSDC == beforeBUSDC + transferAmount)
    }
}

// MARK: - Helpers (local to this file)

private func sendRaw(
    signer: EthereumPKeySigner,
    to: EthereumAddress?,
    value: BigUInt,
    data: Data,
    gasLimit: BigUInt,
    node: AnvilNode,
    client: EthereumRPCClient,
    gasPrice: BigUInt
) async throws -> TransactionReceipt {
    let address = try signer.address()
    let nonce = try await node.transactionCount(of: address)
    let tx = UnsignedLegacyTransaction(
        nonce: nonce,
        gasPrice: gasPrice,
        gasLimit: gasLimit,
        to: to,
        value: value,
        data: data,
        chainId: node.chainId
    )
    let signed = try await signer.sign(transaction: tx.signingData)
    let hash = try await client.broadcast(signed)
    return try await node.waitForReceipt(hash)
}

private struct EthereumAddressVector: Decodable {
    let label: String
    let privateKey: String
    let address: String
}

private func loadEthAddressVectors() -> [EthereumAddressVector] {
    let url = Bundle.module.url(forResource: "ethereum-address", withExtension: "json")!
    // swiftlint:disable:next force_try
    let data = try! Data(contentsOf: url)
    // swiftlint:disable:next force_try
    return try! JSONDecoder().decode([EthereumAddressVector].self, from: data)
}

private let anvilDefaultAccountPrivateKeyHex =
    "0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80"

private func makeEthSigner(privateKeyHex: String, chainId: UInt64) throws -> EthereumPKeySigner {
    let hex = privateKeyHex.hasPrefix("0x") ? String(privateKeyHex.dropFirst(2)) : privateKeyHex
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
