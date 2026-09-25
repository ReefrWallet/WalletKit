# ``WalletKit``

Build secure, non-custodial wallet features for Apple platforms.

## Overview

WalletKit provides the types needed to create and restore wallets, derive
accounts, read blockchain state, build transactions, sign them, and submit
them to a network. It supports software-held and hardware-held accounts across
Bitcoin, Cardano, EVM networks, Solana, Sui, and Tron.

Start with a ``Mnemonic`` to create or restore a wallet. Derive an
``ExtendedKey`` and the chain-specific ``Signer`` for an account, then use a
``BlockchainClientProtocol`` conformer with a
``BlockchainTransactionBuilderProtocol`` to prepare and send transfers.

> Warning: A mnemonic, seed, private key, or private extended-key
> serialization can control wallet funds. Keep these values out of logs,
> analytics, backups that are not encrypted, and user-visible error messages.

## Topics

### Essentials

- <doc:InitializeAWalletAndSendATransaction>
- ``Mnemonic``
- ``Seed``
- ``ExtendedKey``
- ``DerivationPath``
- ``Account``

### Clients and Transactions

- ``BlockchainClientProtocol``
- ``AnyBlockchainClient``
- ``BlockchainTransactionBuilderProtocol``
- ``AnyBlockchainTransactionBuilder``
- ``BlockchainTransaction``
- ``FeeEstimate``

### Networks

- ``Blockchain``
- ``BitcoinNetwork``
- ``CardanoNetwork``
- ``EVMBlockchain``
- ``SolanaNetwork``
- ``SuiNetwork``
- ``TronNetwork``

### Hardware Wallets

- ``HardwareDevice``
- ``HardwareDeviceManagerProtocol``
- ``HardwareDeviceDelegate``

### Testing Support

Use the separate WalletKitTesting reference documentation for local blockchain
nodes and integration-test helpers.
