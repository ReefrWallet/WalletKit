# WalletKit

[![CI](https://github.com/ReefrWallet/WalletKit/actions/workflows/ci.yml/badge.svg?branch=main)](https://github.com/ReefrWallet/WalletKit/actions/workflows/ci.yml)

WalletKit is a Swift toolkit for building non-custodial multi-chain crypto wallet applications on Apple platforms.

> [!WARNING]
> WalletKit is under active development and has not received a production security audit. Do not use it to protect real funds without completing your own security review and testing.

## Features

- **Keys and accounts** — BIP-39 mnemonic generation and import with ten wordlists and optional seed passphrases.
  SLIP-39 share decoding, single-share generation (20 or 33 words), multi-group share-set validation, and cancellable passphrase decryption to a 16–32-byte master secret that seeds BIP-32 and SLIP-0010 derivation.
  BIP-32 secp256k1 and SLIP-0010 Ed25519 key derivation, extended-key serialization, raw private-key import, and address derivation and validation.
- **Blockchain clients** — Balance and token metadata queries, paginated account history, fee estimation, and transaction construction and broadcast.
  Batch balance queries and live transaction or block streams on supported backends.
- **Hardware wallets** — Trezor discovery, connection, public-key retrieval, and on-device signing for supported transactions and messages over USB on macOS.
- **Integration testing** — WalletKitTesting helpers for local Aptos, Bitcoin, Ethereum, Solana, and Sui nodes on macOS,
  including node lifecycle, test account funding, and transaction confirmation.

## Supported blockchains

All eight chains support local transaction signing. Trezor transaction signing is available for Bitcoin, Cardano,
EVM chains, Solana, and Tron.

- **Aptos** — APT, Coin, and Fungible Assets via REST and GraphQL, plus Wallet Standard account authenticators.
- **Bitcoin** — Electrum and Esplora backends, SegWit and Taproot descriptors, watch-only accounts, and PSBTs.
- **Cardano** — ADA and native assets via Blockfrost, BIP-39 and SLIP-39 account derivation, CIP-30 dapp primitives, and native staking.
- **Ethereum and EVM chains** — ERC-20 tokens and approval events, contract calls, and EIP-191 and EIP-712 signing.
- **Solana** — SPL Token, Token-2022, message signing, and native staking.
- **Sui** — gRPC, programmable transactions, and native staking.
- **TON** — Gram on V5R1 wallets via toncenter, deployment on first send, and a restart-safe send pipeline. Software signing only.
- **Tron** — TRC-20 via TronGrid, optional TronScan history, and Stake 2.0.

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
