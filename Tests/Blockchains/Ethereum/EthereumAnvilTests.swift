// Integration tests for
// Sources/Static/Blockchains/Ethereum/EthereumRPCClient.swift against a
// real, running local Ethereum node (Foundry's `anvil`) — nothing before
// this exercised the full path end-to-end: derive a wallet, fund it, sign
// a real transaction, broadcast it, and confirm the chain's own state
// changed by exactly the expected amount. Mirrors the "real infrastructure,
// not a mock" testing philosophy
// Sources/Static/Blockchains/Sui/SuiGRPCClient.swift's tests already
// established for Sui's live testnet, and the "Testable against
// pre-configured test wallets on testnet for every supported blockchain"
// goal in Docs/Overview.md.
//
// USDC is mocked (MockUSDCBytecode.swift), not forked from mainnet: a
// small test-only ERC-20 (hardcoded name/symbol, unrestricted mint)
// deployed fresh on the plain local Anvil chain — no third-party RPC/API
// key, no `anvil_setStorageAt` slot-hacking against a real contract's
// storage layout.
//
// `anvil` is run via `mise x foundry -- anvil` (EthereumNode.swift), which
// auto-installs `foundry` on first use the same way this repo's other
// mise-managed tools already do. There's no `withKnownIssue` gating here:
// if `mise` can't find/run it, or the node never becomes ready, this suite
// fails loudly rather than skipping quietly.

import BigInt
import Foundation
import Testing
import WalletKit
import WalletKitTesting

private struct EthereumAddressVector: Decodable {
    let label: String
    let privateKey: String
    let address: String
}

private func loadAddressVectors() -> [EthereumAddressVector] {
    let url = Bundle.module.url(forResource: "ethereum-address", withExtension: "json")!
    // swiftlint:disable:next force_try
    let data = try! Data(contentsOf: url)
    // swiftlint:disable:next force_try
    return try! JSONDecoder().decode([EthereumAddressVector].self, from: data)
}

private extension String {
    var hexDecoded: Data {
        let hex = hasPrefix("0x") ? String(dropFirst(2)) : self
        var data = Data(capacity: hex.count / 2)
        var index = hex.startIndex
        while index < hex.endIndex {
            let next = hex.index(index, offsetBy: 2, limitedBy: hex.endIndex) ?? hex.endIndex
            data.append(UInt8(hex[index..<next], radix: 16)!)
            index = next
        }

        return data
    }

    /// Parses a JSON-RPC "Quantity" hex string, e.g. a receipt's `gasUsed`.
    var quantity: BigUInt {
        let hex = hasPrefix("0x") ? String(dropFirst(2)) : self
        return BigUInt(hex, radix: 16)!
    }
}

/// Anvil's own well-known default account #0 — pre-funded with 10,000 ETH
/// out of the box, so it can pay deployment/minting gas without needing
/// `EthereumNode.setBalance` itself. Used only as the deployer/minter, kept
/// separate from wallet A/B so their own nonce bookkeeping stays limited to
/// the transfers actually under test.
private let anvilDefaultAccountPrivateKeyHex = "0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80"

private func makeSigner(privateKeyHex: String, chainId: UInt64) throws -> EthereumPKeySigner {
    let privateKey = try PrivateKey(curve: .secp256k1, rawBytes: privateKeyHex.hexDecoded)
    return try EthereumPKeySigner(
        chainId: chainId,
        privateKey: privateKey,
        derivationPath: TestAccountFactory.bip44Path(coinType: 60)
    )
}

@Suite(.timeLimit(.minutes(1)))
struct EthereumAnvilTests {
    // MARK: - Fee estimation

    /// Verifies `feeRates()` and `estimateGas` against a real local Anvil
    /// node: a plain ETH transfer costs exactly 21 000 gas.
    @Test func feeRatesAndNativeTransferGasEstimate() async throws {
        let node = try await EthereumNode.start()
        defer { node.stop() }

        let vectors = loadAddressVectors()
        let walletB = try EthereumAddress(string: vectors[1].address)
        let client = EthereumRPCClient(endpoint: node.endpoint, chainId: node.chainId)

        let rates = try await client.feeRates()
        #expect(rates.gasPrice > 0)
        #expect(rates.maxFeePerGas >= rates.maxPriorityFeePerGas)

        let oneEther = BigUInt(1_000_000_000_000_000_000)
        let gasLimit = try await client.estimateGas(from: nil, to: walletB, value: oneEther)
        #expect(gasLimit == 21_000)
    }

    // MARK: - Transfer

    // swiftlint:disable:next function_body_length
    @Test func twoWalletsExchangeETHAndMockUSDC() async throws {
        let node = try await EthereumNode.start()
        defer { node.stop() }

        let vectors = loadAddressVectors()
        let signerA = try makeSigner(privateKeyHex: vectors[0].privateKey, chainId: node.chainId)
        let signerB = try makeSigner(privateKeyHex: vectors[1].privateKey, chainId: node.chainId)
        let deployerSigner = try makeSigner(privateKeyHex: anvilDefaultAccountPrivateKeyHex, chainId: node.chainId)
        let walletA = try signerA.address()
        let walletB = try signerB.address()

        let client = EthereumRPCClient(endpoint: node.endpoint, chainId: node.chainId)
        let gasPrice = try await node.gasPrice()

        func sendAndConfirm(
            signer: EthereumPKeySigner,
            to: EthereumAddress?,
            value: BigUInt,
            data: Data,
            gasLimit: BigUInt
        ) async throws -> TransactionReceipt {
            let address = try signer.address()
            let nonce = try await node.transactionCount(of: address)
            let transaction = UnsignedLegacyTransaction(
                nonce: nonce,
                gasPrice: gasPrice,
                gasLimit: gasLimit,
                to: to,
                value: value,
                data: data,
                chainId: node.chainId
            )
            let signed = try await signer.sign(transaction: transaction.signingData)
            let hash = try await client.broadcast(signed)
            let receipt = try await node.waitForReceipt(hash)
            #expect(receipt.status == "0x1", "transaction from \(address.string) reverted")
            return receipt
        }

        // Fund both wallets with ETH
        let oneEther = BigUInt(1_000_000_000) * BigUInt(1_000_000_000)
        try await node.setBalance(walletA, wei: oneEther * 10)
        try await node.setBalance(walletB, wei: oneEther * 10)

        // Deploy the mock USDC contract.
        let deployReceipt = try await sendAndConfirm(
            signer: deployerSigner,
            to: nil,
            value: 0,
            data: mockUSDCCreationBytecode,
            gasLimit: 1_000_000
        )
        let mockUSDCAddress = try EthereumAddress(string: try #require(deployReceipt.contractAddress))

        // Mint 1,000 mock USDC (6 decimals) to both wallets.
        let mintAmount = BigUInt(1_000_000_000)
        for wallet in [walletA, walletB] {
            _ = try await sendAndConfirm(
                signer: deployerSigner,
                to: mockUSDCAddress,
                value: 0,
                data: EthereumABI.encodeCall(
                    selector: EthereumABI.selector("mint(address,uint256)"),
                    parameters: [.address(wallet), .uint256(mintAmount)]
                ),
                gasLimit: 100_000
            )
        }

        let beforeAETH = try await client.nativeBalance(of: walletA)
        let beforeBETH = try await client.nativeBalance(of: walletB)
        let beforeAUSDC = try await client.erc20Balance(token: mockUSDCAddress, owner: walletA)
        let beforeBUSDC = try await client.erc20Balance(token: mockUSDCAddress, owner: walletB)

        // ETH transfer: A -> B.
        let ethTransferAmount = oneEther
        let ethReceipt = try await sendAndConfirm(
            signer: signerA,
            to: walletB,
            value: ethTransferAmount,
            data: Data(),
            gasLimit: 21_000
        )

        // Mock USDC transfer: A -> B.
        let usdcTransferAmount = BigUInt(100_000_000) // 100 USDC
        let usdcReceipt = try await sendAndConfirm(
            signer: signerA,
            to: mockUSDCAddress,
            value: 0,
            data: EthereumABI.encodeCall(
                selector: EthereumABI.selector("transfer(address,uint256)"),
                parameters: [.address(walletB), .uint256(usdcTransferAmount)]
            ),
            gasLimit: 100_000
        )

        let afterAETH = try await client.nativeBalance(of: walletA)
        let afterBETH = try await client.nativeBalance(of: walletB)
        let afterAUSDC = try await client.erc20Balance(token: mockUSDCAddress, owner: walletA)
        let afterBUSDC = try await client.erc20Balance(token: mockUSDCAddress, owner: walletB)

        #expect(afterAUSDC == beforeAUSDC - usdcTransferAmount)
        #expect(afterBUSDC == beforeBUSDC + usdcTransferAmount)

        // Read each transaction's *actual* gas cost from its receipt rather
        // than trusting the `gasLimit` used to build it, so the ETH-balance
        // assertion below is exact rather than approximate.
        let ethFee = ethReceipt.gasUsed.quantity * (ethReceipt.effectiveGasPrice?.quantity ?? gasPrice)
        let usdcFee = usdcReceipt.gasUsed.quantity * (usdcReceipt.effectiveGasPrice?.quantity ?? gasPrice)

        #expect(afterAETH == beforeAETH - ethTransferAmount - ethFee - usdcFee)
        #expect(afterBETH == beforeBETH + ethTransferAmount)
    }
}
