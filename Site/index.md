---
title: WalletKit
pagetitle: WalletKit Documentation
description: A Swift toolkit for building non-custodial wallet applications on Apple platforms.
---

A Swift toolkit for building non-custodial wallet applications on Apple platforms.

::: {.notice}
**Warning:** WalletKit is under active development and has not received a production security audit.
Do not use it to protect real funds without completing your own security review and testing.
:::

:::: {.modules}

::: {.module}
## [WalletKit](documentation/walletkit/)

Create and restore wallets, derive accounts, read blockchain state, and build, sign and broadcast
transactions with software-held or hardware-held keys.

- BIP-39 mnemonics, BIP-32 secp256k1 and SLIP-0010 ed25519 derivation
- Bitcoin, Cardano, Ethereum and EVM chains, Solana, Sui, and Tron
- Balances, transaction history, fee estimation, and transaction construction
- Local signing, and Trezor hardware wallets over USB on macOS

[Open the WalletKit reference](documentation/walletkit/){.button}
:::

::: {.module}
## [WalletKitTesting](documentation/walletkittesting/)

Run WalletKit integration tests against isolated local blockchain nodes. Each helper owns its
node's lifecycle on its own ports, so tests can fund accounts, send transfers, and wait for
results in parallel.

- `EthereumNode`: an Anvil EVM node, with ERC-20 helpers
- `BitcoinNode`: a regtest `bitcoind` with `electrs`
- `SolanaNode`: a `solana-test-validator`
- `SuiNode`: a local Sui network

For macOS test targets only, not for an app's production runtime.

[Open the WalletKitTesting reference](documentation/walletkittesting/){.button}
:::

::::

Source code, issues and releases are on [GitHub](https://github.com/ReefrWallet/WalletKit).
WalletKit is licensed under the BSD 3-Clause License.
