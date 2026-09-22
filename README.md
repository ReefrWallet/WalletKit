# WalletKit

WalletKit is a source-first Swift toolkit for building non-custodial wallet
applications on Apple platforms. Its cryptographic core is implemented in Rust
and exposed through an idiomatic Swift API using UniFFI.

> [!WARNING]
> WalletKit is under active development and has not received a production
> security audit. Do not use it to protect real funds without completing your
> own security review and testing.

## What it provides

| Area | Current capabilities |
| --- | --- |
| Keys | BIP-39 mnemonic generation and import; BIP-39 seed derivation; BIP-32 secp256k1 and SLIP-0010 ed25519 derivation; extended-key serialization; arbitrary-precision integers. |
| Hardware wallets | Trezor discovery, connection, public-key retrieval, and Ethereum and Bitcoin transaction signing over USB on macOS. |
| Bitcoin | Experimental descriptor wallets: BIP-84 native SegWit and BIP-86 Taproot derivation; single-address watch-only accounts; gap-limit discovery; balances, transaction history, fee estimation, PSBT construction, local or Trezor signing, and broadcast through Electrum or Esplora. |
| Ethereum | Address derivation and validation, legacy EIP-155 and EIP-1559 transaction signing, transaction construction, JSON-RPC access, and ERC-20 support. |
| Sui | Address derivation and validation, BCS transaction construction and signing, and a gRPC client. |

The Swift façade lives in `Sources/WalletKit`; the Rust implementation and
UniFFI export layer live in `Sources/Rust`.

## Platform and distribution status

WalletKit targets iOS, iPadOS, and macOS and includes a Swift Package manifest.
The native XCFramework, UniFFI bindings, and Sui gRPC sources are generated
inputs, they are built automatically when building a Swift package:

```sh
make spm
```

Use a local package dependency while developing with WalletKit:
 
```swift
.package(path: "../WalletKit")
```

Publishing it as a URL dependency additionally requires shipping the generated
XCFramework and Swift sources as part of the release artifact.

Bitcoin supports mainnet, testnet, signet, and regtest. `BitcoinClient` can be
initialized with an Electrum host/port or an Esplora endpoint. Default public
endpoints are available through `BitcoinNetwork`, but self-hosted endpoints are
recommended when privacy or reliability matters; regtest always needs a local
endpoint. Electrum supports header subscriptions, while Esplora uses polling.

Other listed network types—Cardano, Solana, and Tron—are extension points
only, not functional chain clients.

## Requirements

- macOS with Xcode Command Line Tools for Apple-framework builds
- Rust and `rustup`
- Git submodules, for Sui's gRPC protocol definitions
- For Sui gRPC bindings: `protoc`, `protoc-gen-swift`, and
  `protoc-gen-grpc-swift` v2 (for example,
  `brew install protobuf swift-protobuf protoc-gen-grpc-swift`)

## Getting started

Clone recursively so the Sui protocol definitions are available:

```sh
git clone --recurse-submodules https://github.com/kervich/WalletKit.git
cd WalletKit
```

Build the source-generated inputs:

```sh
make walletkit-ffi sui-grpc
```

Build the Apple XCFramework and Swift bindings when working with the Swift
targets:

```sh
make walletkit-ffi
```

Generate the Sui gRPC Swift sources when they need to be refreshed:

```sh
make sui-grpc
```

`make rust-tests` runs only the host Rust suite. `make all` runs both
generation pipelines and both test suites, after the Bitcoin integration-test
prerequisites below are available. See
[Sources/Rust/README.md](Sources/Rust/README.md) for more details.

## Testing

Rust tests live beside the implementation. Shared vectors in `TestVectors/`
cover BIP-39, Ethereum addresses and transactions, and Sui addresses and
transactions; they keep the Rust and Swift layers aligned on the same expected
results. Swift tests live in `Tests/` and include unit coverage plus local-node
integration coverage.

The Bitcoin regtest integration suite exercises both Electrum and Esplora
against a real local `bitcoind` and Blockstream `electrs` instance. Provision
the binaries once before running that suite; the initial `electrs` build takes
several minutes:

```sh
make bitcoin-testing
make test
```

## Project layout

| Path | Purpose |
| --- | --- |
| `Sources/WalletKit/` | Public Swift API, chain clients, and transaction builders |
| `Sources/Rust/` | Rust cryptography, hardware abstractions, and UniFFI layer |
| `Sources/gRPC/` | Sui gRPC protocol submodule and generated-source inputs |
| `TestVectors/` | Cross-language test vectors |
| `Tests/` | Swift unit and integration tests |
| `Docs/Overview.md` | Architecture notes and longer-term design |

## Hardware wallet scope

Trezor over USB is the only current hardware-wallet path, and it is macOS-only.
Bluetooth and air-gapped transports, other vendors, and iOS hardware-wallet
support are not implemented.

## Contributing

Please keep cryptographic and transaction-format changes accompanied by test
vectors or other interoperable fixtures. Avoid adding secrets, seed phrases, or
funded private keys to the repository or its test output.
