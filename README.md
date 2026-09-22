# WalletKit

[![CI](https://github.com/kervich/WalletKit/actions/workflows/ci.yml/badge.svg?branch=main)](https://github.com/kervich/WalletKit/actions/workflows/ci.yml)

WalletKit is a source-first Swift toolkit for building non-custodial wallet applications on Apple platforms. Its cryptographic core is implemented in Rust and exposed through an idiomatic Swift API using UniFFI.

> [!WARNING]
> WalletKit is under active development and has not received a production security audit. Do not use it to protect real funds without completing your own security review and testing.

## Features

 - BIP-39 mnemonic generation and import. BIP-39 seed derivation. 
 - BIP-32 secp256k1 and SLIP-0010 ed25519 derivation. Extended-key serialization
 - Hardware wallets: Trezor discovery, connection, public-key retrieval, transaction signing over USB on macOS.

## Blockchain support

- **Bitcoin**: BIP-84 native SegWit and BIP-86 Taproot derivation; single-address watch-only accounts; gap-limit discovery, fee estimation, PSBT construction, local or Trezor signing, and broadcast through Electrum or Esplora.
- **Cardano**: CIP-1852 account and Shelley address derivation; Blockfrost account, UTxO, and native-asset data; ADA and native-asset transaction construction, local or Trezor signing, and submission.
- **Ethereum**: address derivation and validation, EIP-155 and EIP-1559 transaction signing, transaction construction, JSON-RPC access; ERC-20 support; local or Trezor signing.
- **Solana**: address derivation and validation; SOL and SPL token account data, fee estimation, transaction construction, local or Trezor signing, and RPC broadcast.
- **Sui**: address derivation and validation, BCS transaction construction and signing, and a gRPC client.
- **Tron**: address derivation and validation; TRX and TRC-20 account data, transaction history, fee estimation, transaction construction, local or Trezor signing, and TronGrid broadcast.

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

## Requirements

- macOS with Xcode Command Line Tools for Apple-framework builds
- Rust and `rustup`
- For Sui gRPC bindings: `protoc`, `protoc-gen-swift`, and `protoc-gen-grpc-swift` v2 (for example, `brew install protobuf swift-protobuf protoc-gen-grpc-swift`)
- `mise`

## License

WalletKit is licensed under the BSD 3-Clause License.
