# Initialize a Wallet and Send a Transaction

Create an Ethereum account from a new recovery phrase and submit a native ETH transfer.

## Overview

This tutorial uses an Ethereum testnet endpoint. Replace the endpoint and
recipient with values appropriate for your application, and present the
transfer details to the person before requesting a signature.

## Create the Wallet

Generate a recovery phrase, derive the first Ethereum BIP-44 account, and
create a signer for the selected chain. Store the recovery phrase using your
application's secure backup flow before deriving accounts from it.

```swift
import Foundation
import WalletKit

let chainId: UInt64 = 11_155_111 // Sepolia

let mnemonic = Mnemonic.generate(wordCount: .words24)

let derivationPath = try DerivationPath(
    .evm(EVMBlockchain(chainId: chainId)), 
    accountIndex: 0
)

let privateKey = try mnemonic.toSeed()
    .masterKey(curve: derivationPath.curve)
    .derive(derivationPath)
    .privateKey()
    
let signer = try EthereumPKeySigner(
    chainId: chainId,
    privateKey: privateKey,
    derivationPath: derivationPath
)

let sender = try signer.address()
```

Never print or transmit `mnemonic.phrase`, `seed`, or `privateKey`. An
application normally retains only the encrypted wallet material it needs to
restore the account later.

## Build, Sign, and Broadcast a Transfer

Use a client for the same chain as the signer. The transaction builder retrieves 
the current nonce and fee information before preparing the unsigned transfer.

```swift
import BigInt

let client = EthereumRPCClient(
    endpoint: URL(string: "https://your-sepolia-rpc.example")!,
    chainId: chainId
)

let recipient = try EthereumAddress(
    string: "0x000000000000000000000000000000000000dEaD"
)

let transactionBuilder = EthereumTransactionBuilder(client: client)

let unsignedTransaction = try await transactionBuilder.buildTransfer(
    sender: sender,
    recipient: recipient,
    amount: BigUInt(1_000_000_000_000_000) // 0.001 ETH in wei
)

let signedTransaction = try await signer.sign(transaction: unsignedTransaction)
let transactionHash = try await client.broadcast(signedTransaction)
```

`broadcast(_:)` reports that the node accepted the transaction; it is not a
confirmation. Continue observing the transaction or refresh the account state
until the required confirmation policy is met.

## See Also

- ``EthereumRPCClient``
- ``EthereumTransactionBuilder``
- ``EthereumPKeySigner``
- ``BlockchainTransaction``
