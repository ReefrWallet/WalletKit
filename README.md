# WalletKit

[![CI](https://github.com/ReefrWallet/WalletKit/actions/workflows/ci.yml/badge.svg?branch=main)](https://github.com/ReefrWallet/WalletKit/actions/workflows/ci.yml)

WalletKit is a Swift toolkit for building non-custodial multi-chain crypto wallet applications on Apple platforms.

> [!WARNING]
> WalletKit is under active development and has not received a production security audit. Do not use it to protect real funds without completing your own security review and testing.

## Features

- **Keys and accounts** — BIP-39 mnemonic generation and import with ten wordlists and optional seed passphrases.
  BIP-32 secp256k1 and SLIP-0010 Ed25519 key derivation, extended-key serialization, raw private-key import, and address derivation and validation.
- **Blockchain clients** — Balance and token metadata queries, paginated account history, fee estimation, and transaction construction and broadcast.
  Batch balance queries and live transaction or block streams on supported backends.
- **Hardware wallets** — Trezor discovery, connection, public-key retrieval, and on-device signing for supported transactions and messages over USB on macOS.
- **Integration testing** — WalletKitTesting helpers for local Aptos, Bitcoin, Ethereum, Solana, and Sui nodes on macOS,
  including node lifecycle, test account funding, and transaction confirmation.

## Supported blockchains

- **Aptos** — Node REST and indexer GraphQL support for APT, Coin, and Fungible Asset balances and history.
  BCS transfer construction, simulation-based gas estimation, transaction submission, and status queries.
  Local Ed25519 transaction and message signing and Wallet Standard account authenticator generation.
- **Bitcoin** — BIP-84 native SegWit and BIP-86 Taproot descriptors, single-address watch-only accounts, and gap-limit address discovery.
  Balances, UTxOs, transaction history, fee estimation, PSBT construction, local or Trezor signing, and Electrum or Esplora broadcast.
- **Cardano** — CIP-1852 account and Shelley address derivation, receive-address discovery and rotation, and per-address ADA balances.
  Blockfrost account, UTxO, native-asset, and history queries and transaction submission. ADA and native-asset transfer construction and local or Trezor signing.
  CIP-30 dapp primitives for CBOR balance and UTxO reads, transaction decoding, signer resolution, witness signing, and CIP-8 data signing.
  Native staking with stake and reward queries, stake registration, pool and DRep delegation, reward withdrawal, and stake deregistration.
- **Ethereum and EVM chains** — Native and ERC-20 balances, metadata, and history over JSON-RPC, including ERC-20 approval events.
  Gas estimation, ABI encoding, and EIP-1559 and legacy EIP-155 transaction construction for transfers and arbitrary contract calls.
  Local or Trezor signing for transactions, EIP-191 personal messages, and EIP-712 typed data. Transaction broadcast over JSON-RPC.
- **Solana** — SOL, SPL Token, and Token-2022 balances, token metadata, and history over RPC.
  Transfer construction, base and priority fee estimation, legacy and version 0 wire transaction decoding, and RPC broadcast.
  Local or Trezor transaction signing, local raw message signing, and Trezor OCMS v1 text signing.
  Native staking with stake-account discovery, validator and reward data, delegation, full and partial deactivation, and withdrawal.
- **Sui** — gRPC queries for coin balances, history, objects, and Move function signatures.
  BCS transfer and programmable transaction construction, transaction data decoding, gas simulation, and broadcast.
  Local transaction and personal-message signing. Native staking with validator and stake queries, reward estimation, delegation,
  full and partial unstaking, and pending submission resolution.
- **Tron** — TRX and TRC-20 balances and history through TronGrid, with optional TronScan history for internal TRX transfers.
  Transfer construction, bandwidth and energy cost estimation, raw transaction decoding, and TronGrid broadcast.
  Local or Trezor transaction signing and local TIP-191 message signing. Stake 2.0 support for bandwidth and energy staking,
  unstaking, withdrawal, representative voting, reward claims, and local-key cancellation of pending unstakes.

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
