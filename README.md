# WalletKit

[![CI](https://github.com/ReefrWallet/WalletKit/actions/workflows/ci.yml/badge.svg?branch=main)](https://github.com/ReefrWallet/WalletKit/actions/workflows/ci.yml)

WalletKit is a Swift toolkit for building non-custodial multi-chain crypto wallet applications on Apple platforms.

> [!WARNING]
> WalletKit is under active development and has not received a production security audit. Do not use it to protect real funds without completing your own security review and testing.

## Features

 - BIP-39 mnemonic generation and import. BIP-39 seed derivation. 
 - BIP-32 secp256k1 and SLIP-0010 ed25519 derivation. Extended-key serialization.
 - Hardware wallets: Trezor discovery, connection, public-key retrieval, transaction signing over USB on macOS.
 - Local blockchain node testing infrastructure.

## Supported Blockchains:

- **Bitcoin**: BIP-84 native SegWit and BIP-86 Taproot derivation; single-address watch-only accounts; gap-limit discovery, transaction history, fee estimation, PSBT construction, local or Trezor signing, and broadcast through Electrum or Esplora.
- **Cardano**: CIP-1852 account and Shelley address derivation; Blockfrost account, UTxO, native-asset data, and transaction history; ADA and native-asset transaction construction, local or Trezor signing, and submission.
- **Ethereum and EVM chains**: address derivation and validation; native and ERC-20 balances, transaction history, and fee estimation over JSON-RPC; EIP-1559 and legacy EIP-155 transaction construction, including arbitrary contract calls; EIP-191 and EIP-712 message signing; local or Trezor signing.
- **Solana**: address derivation and validation; SOL and SPL token account data, transaction history, fee estimation, transaction construction, off-chain message signing, local or Trezor signing, and RPC broadcast.
- **Sui**: address derivation and validation; coin balances and transaction history over gRPC; BCS transaction construction, and transaction and personal-message signing. Local signing only.
- **Tron**: address derivation and validation; TRX and TRC-20 account data, transaction history, fee estimation, transaction construction, local or Trezor signing, and TronGrid broadcast.

## Requirements

- macOS with Xcode Command Line Tools for Apple-framework builds
- `protoc`, `protoc-gen-swift`, and `protoc-gen-grpc-swift` v2:

  ```shell
  brew install protobuf swift-protobuf protoc-gen-grpc-swift
  ```

- `mise`:

  ```shell
  curl -fsSL https://mise.run | sh
  ```

## Getting started

Install mise dependencies:

```shell
mise install
```

Build:

```shell
make spm
```

Use as a local SPM dependency while developing with WalletKit:
 
```swift
.package(path: "../WalletKit")
```

### Example: Ethereum

```swift
import WalletKit

let rpcURL = URL(string: "https://your-mainnet-rpc.example.net")!
let client = EthereumRPCClient(endpoint: rpcURL, chainId: 1)

let mnemonic = Mnemonic.generate(wordCount: .`12`)
let derivationPath = try DerivationPath(.evm(EVMBlockchain(chainId: 1)), accountIndex: 0)
let privateKey = try mnemonic.toSeed()
    .masterKey(curve: derivationPath.curve)
    .derive(derivationPath)
    .privateKey()

let signer = try EthereumPKeySigner(chainId: 1, privateKey: privateKey, derivationPath: path)
let myAddress = try signer.address()
print("My address:", myAddress.checksummed)

let weth = try EthereumAddress(string: "0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2")
let balance = try await client.call(
    to: weth,
    data: EthereumABI.encodeCall(
        selector: EthereumABI.selector("balanceOf(address)"),
        parameters: [.address(myAddress)]
    )
)
print("My WETH balance (wei):", EthereumABI.decodeUInt256(balance))

let builder = EthereumTransactionBuilder(client: client)
let unsigned = try await builder.buildCall(
    sender: myAddress,
    to: weth,
    value: BigUInt(10).power(16),
    data: EthereumABI.encodeCall(selector: EthereumABI.selector("deposit()"))
)

let signed = try await signer.sign(transaction: unsigned)
let txHash = try await client.broadcast(signed)
print("WETH deposit tx hash:", txHash)
```

## Full Documentation

- [WalletKit API reference and guides](https://reefrwallet.github.io/WalletKit/documentation/walletkit/)
- [WalletKitTesting API reference](https://reefrwallet.github.io/WalletKit/documentation/walletkittesting/)

## License

WalletKit is licensed under the BSD 3-Clause License.
