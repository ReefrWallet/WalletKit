# ``WalletKitTesting``

Run WalletKit integration tests against isolated local blockchain nodes.

## Overview

WalletKitTesting re-exports `WalletKit` and provides local-node helpers for
integration tests. Each helper owns the node lifecycle and exposes the
operations needed to fund accounts, create transfers, and wait for observable
results.

Use these APIs from macOS test targets only. They are not intended for an
application's production runtime.

## Topics

### EVM

- ``EthereumNode``
- ``TransactionReceipt``
- ``EthereumLaunchError``

### Bitcoin

- ``BitcoinNode``
- ``BitcoinLaunchError``

### Solana

- ``SolanaNode``
- ``SolanaLaunchError``

### Sui

- ``SuiNode``
- ``SuiLaunchError``
