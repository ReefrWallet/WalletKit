# WalletKit

WalletKit is a source-first Swift toolkit for building non-custodial wallet applications on Apple platforms. Its cryptographic core is implemented in Rust and exposed through an idiomatic Swift API using UniFFI.

> [!WARNING]
> WalletKit is under active development and has not received a production security audit. Do not use it to protect real funds without completing your own security review and testing.

## Features

 - BIP-39 mnemonic generation and import. BIP-39 seed derivation. 
 - BIP-32 secp256k1 and SLIP-0010 ed25519 derivation. Extended-key serialization
 - Hardware wallets: Trezor discovery, connection, public-key retrieval, transaction signing over USB on macOS.

## Blockchain support

| --- | --- |
| Bitcoin | Experimental descriptor wallets: BIP-84 native SegWit and BIP-86 Taproot derivation; single-address watch-only accounts; gap-limit discovery; balances, transaction history, fee estimation, PSBT construction, local or Trezor signing, and broadcast through Electrum or Esplora. |
| Cardano | CIP-1852 account and Shelley address derivation; Blockfrost account, UTxO, and native-asset data; ADA and native-asset transaction construction, local or Trezor signing, and submission. |
| Ethereum | Address derivation and validation, legacy EIP-155 and EIP-1559 transaction signing, transaction construction, JSON-RPC access, and ERC-20 support, local or Trezor signing. |
| Solana | Address derivation and validation; SOL and SPL token account data, transaction history, fee estimation, transaction construction, local or Trezor signing, and RPC broadcast. |
| Sui | Address derivation and validation, BCS transaction construction and signing, and a gRPC client. |
| Tron | Address derivation and validation; TRX and TRC-20 account data, transaction history, fee estimation, transaction construction, local or Trezor signing, and TronGrid broadcast. |

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

Copyright (c) 2026, Andrey Yurkevich. All rights reserved.

Redistribution and use in source and binary forms, with or without modification, are permitted provided that the following conditions are met:

1. Redistributions of source code must retain the above copyright notice, this list of conditions and the following disclaimer.

2. Redistributions in binary form must reproduce the above copyright notice, this list of conditions and the following disclaimer in the documentation and/or other materials provided with the distribution.

3. Neither the name of the copyright holder nor the names of its contributors may be used to endorse or promote products derived from this software without specific prior written permission.

THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS "AS IS" AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE ARE DISCLAIMED. IN NO EVENT SHALL THE COPYRIGHT HOLDER OR CONTRIBUTORS BE LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE OF THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.
