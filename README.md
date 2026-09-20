# WalletKit

Crypto wallet utilities for Swift, using Rust implementations. WalletKit is
the shared key-management and blockchain-access core for Reefr Wallet.

See `Docs/Overview.md` for the full architecture and rationale, not all of it 
implemented yet — see "Status" below).

## Features

- BIP39 mnemonic generation/import (12/15/18/21/24 words) and BIP39 seed
  derivation, wordlist-aware
- BIP32 (secp256k1) and SLIP-0010 (ed25519) hierarchical key derivation
  from a path (`m/44'/60'/0'/0/0`), plus xpub/xprv-style serialization
- Arbitrary-precision integers (`BigInt`/`BigUInt`) bridged across the FFI
  boundary for balances, gas prices, and `uint256`/`int256`-shaped values
- Ethereum: EIP-55 checksummed address derivation, address
  parsing/validation, and legacy/EIP-155 transaction signing (RLP decode →
  sign → re-encode) from a raw `PrivateKey`
- Sui: address derivation (Blake2b-256 of scheme flag + public key,
  ed25519 and secp256k1) and address parsing/validation
- Hardware wallet support (`HardwareDevice`, `HardwareDeviceManager`,
  `HardwareDeviceDelegate`) for Trezor over USB — device discovery,
  connection, public-key retrieval, and Ethereum transaction signing
  (`EthereumTrezorSigner`), with PIN/passphrase/button prompts relayed to
  the app through `HardwareDeviceDelegate`. USB is macOS-only (see
  "Status"); Bluetooth/other transports aren't implemented.

## Status

This is early and under active development. Notably not implemented yet:

- Sui transaction signing (BCS encoding + intent-signing wrapper)
- Signing through an `Account` rather than a raw `PrivateKey`
  (`Signer.sign(transaction:account:)` currently throws)
- Hardware wallet support beyond Trezor-over-USB: Bluetooth/QR-air-gap
  transports, other vendors (Ledger, Keystone, ...), and iOS (Trezor
  devices aren't MFi-certified, so iOS has no generic USB HID access —
  Trezor Safe 7's Bluetooth would be the first real iOS story)
- Any chain beyond Ethereum and Sui (Bitcoin, Tron, Solana, Cardano are
  identifier-only extension points)

## Building

The Rust crate, XCFramework packaging, and Swift binding generation are
driven by the top-level `Makefile`:

```sh
make walletkit-ffi   # build the Rust crate + package XCFramework + Swift bindings
make test            # run the Rust test suite
```

See `Rust/README.md` for host-only Rust iteration (`cargo build`/`cargo
test` without the full cross-platform build).

## Testing

Rust-side unit tests live alongside the code they cover and run against
shared JSON test vectors in `TestVectors/` (BIP39, Ethereum address/tx,
Sui address) so both the Rust crate and its Swift bindings can be checked
against identical expected output. See "Testing strategy" in
`Docs/Overview.md` for the full two-layer (Rust + Swift) approach.
