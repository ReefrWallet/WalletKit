# ``WalletKit``

Build secure, non-custodial wallet features for Apple platforms.

## Overview

WalletKit provides the types needed to create and restore wallets, derive
accounts, read blockchain state, build transactions, sign them, and submit
them to a network. It supports software-held and hardware-held accounts across
Bitcoin, Cardano, EVM networks, Solana, Sui, TON, and Tron.

Start with a ``Mnemonic`` (or a SLIP-39 share, see ``Slip39``) to create or restore a wallet. Derive an
``ExtendedKey`` and the chain-specific ``Signer`` for an account, then use a
``BlockchainClientProtocol`` conformer with a
``BlockchainTransactionBuilderProtocol`` to prepare and send transfers.

> Warning: A mnemonic, SLIP-39 share or master secret, seed, private key, or private extended-key
> serialization can control wallet funds. Keep these values out of logs,
> analytics, backups that are not encrypted, and user-visible error messages.

## Topics

### Essentials

- <doc:InitializeAWalletAndSendATransaction>
- ``Mnemonic``
- ``Seed``
- ``Slip39``
- ``Slip39ShareSet``
- ``Slip39EncryptedSecret``
- ``Slip39GeneratedShare``
- ``ExtendedKey``
- ``DerivationPath``
- ``Account``

### Clients and Transactions

- ``BlockchainClientProtocol``
- ``BlockchainTransactionBuilderProtocol``
- ``BlockchainTransaction``

### Networks

- ``Blockchain``
- ``BitcoinNetwork``
- ``CardanoNetwork``
- ``EVMBlockchain``
- ``SolanaNetwork``
- ``SuiNetwork``
- ``TonNetwork``
- ``TronNetwork``

### Hardware Wallets

- ``HardwareDevice``
- ``HardwareDeviceManagerProtocol``
- ``HardwareDeviceDelegate``

### Testing Support

Use the separate WalletKitTesting reference documentation for local blockchain
nodes and integration-test helpers.
