# WalletKit — Architecture Overview

WalletKit is the shared key-management and blockchain-access core for
Reefr Wallet. It is implemented in Rust and exposed to Swift (iOS/macOS) 
via UniFFI. This document covers mnemonic-based key management plus
hardware wallets (Trezor first) as a second, first-class key source, plus
Ethereum address derivation and transaction signing, and Sui address
derivation, as the first concrete chain clients (Sui transaction signing
isn't speced yet). Other chain clients (Bitcoin, Tron, Solana, Cardano)
are a later phase and are called out below only as extension points.


## Goals

- Single audited Rust core for all cryptography and key derivation; no
  duplicated crypto logic on the Swift side.
- Modular crate layout so blockchain-specific clients can be added later
  without touching the key-management core.
- Swift-facing API that reads as idiomatic Swift, not a thin C shim —
  UniFFI's Swift bindings should feel native to a GUI app.
- Security-first FFI boundary: sensitive material stays opaque and inside
  Rust wherever possible; raw exports are explicit, rare, and clearly named.
- Testable against official BIP39 / BIP32 / SLIP-0010 test vectors from day
  one, independent of any chain client.
- Testable against pre-configured test wallets on testnet for every
  supported blockchain.
- Hardware wallets (Trezor first) are a key *source*, not a bolted-on
  special case — a chain has one `Signer` protocol and two conformers, a
  software one (bound to a `PrivateKey`) and a hardware one (bound to a
  connected `HardwareDevice`), sharing the address-derivation and
  RLP/BCS-decoding logic and diverging only where the underlying reality
  actually differs (the device conversation itself).

## Crate layout

- `walletkit-keys` — software key management. BIP39 mnemonics, seed
  derivation, BIP32 (secp256k1) and SLIP-0010 (ed25519) hierarchical
  derivation, signing. No networking, no persistence, no chain-specific
  logic.
- `walletkit-hardware` — vendor-agnostic hardware wallet plumbing: the
  `HardwareDevice`/`HardwareDeviceManager`/`HardwareDeviceDelegate` traits,
  transport/vendor enumeration, and error mapping (`HardwareError`).
  Defines the contract; carries no vendor protocol code itself. (`Account`
  has no Rust representation at all — see "FFI / bindings strategy" — so
  it isn't one of these traits.)
- `walletkit-trezor` — implements `walletkit-hardware`'s traits for Trezor
  devices. Wraps the official `trezor-client` crate (from
  `trezor/trezor-firmware`, the Trezor team's own Rust client covering the
  wire protocol/protobuf messages) rather than reimplementing the protocol
  — same "don't hand-roll audited/reference protocol code" principle as
  the crypto primitives. USB is implemented (macOS only — see "Transport
  and platform constraints"); Bluetooth (needed for Trezor Safe 7 on iOS)
  isn't built yet.
- `walletkit-ffi` — UniFFI export layer. Wraps `walletkit-keys`,
  `walletkit-hardware` (+ vendor crates), and later chain crates behind
  `#[uniffi::export]` proc-macros; this is what gets compiled into the
  XCFramework Swift links against. Also where UniFFI's callback-interface
  support is wired up so `HardwareDeviceDelegate` (Swift) can be called
  from in-flight Rust/device operations.
- `walletkit-ethereum` — concrete `walletkit-<chain>` crate (see
  below). Implements `EthereumSignerFfi::address`, backing both
  `EthereumPKeySigner.address()` and `EthereumTrezorSigner.address()`:
  returns a dedicated `EthereumAddress` type rather than a raw `String` —
  Keccak-256 hash of the account's uncompressed secp256k1 public key, last
  20 bytes, wrapped as `EthereumAddress`'s raw bytes; `EthereumAddress.checksummed`
  computes the EIP-55 mixed-case encoding on demand. `EthereumAddress`
  conforms to the shared `BlockchainAddress` protocol (see below) and has
  throwing `init(string:)`/`init(rawBytes:)` for parsing/validating an
  address the host app received as text or bytes (e.g. pasted, scanned, or
  read back from storage), throwing `.invalidAddress` on malformed input.
  Signing splits into three composable pieces on `EthereumSignerFfi`, all
  RLP-decoding/re-encoding the same EIP-155 unsigned transaction blob:
  `decode_signing_data` (into the structured fields a Trezor's trusted
  screen displays), `signature` (Keccak-256 hash + software ECDSA via a
  `PrivateKey`), and `encode_signed` (structured `v`/`r`/`s` → broadcastable
  RLP). `EthereumPKeySigner.sign(transaction:)` composes all three;
  `EthereumTrezorSigner` calls `decode_signing_data`/`encode_signed`
  directly and gets its `signature` from the device instead — once a
  device conversation exists (see "Hardware wallet support"). Depends
  only on `walletkit-keys` for `PublicKey`/`PrivateKey` — no networking,
  no transaction *building*; that stays out of scope (see "Explicitly out
  of scope for now"). Fee estimation lives on the Swift RPC/gRPC clients
  (`EthereumRPCClient`/`SuiGRPCClient`), not in the Rust layer. Tested
  against the shared vectors in `TestVectors/ethereum-address.json` and
  `TestVectors/ethereum-tx.json` (see "Testing strategy").
- `walletkit-sui` — concrete `walletkit-<chain>` crate.
  Implements `SuiSignerFfi::address`, backing `SuiPKeySigner.address()`:
  returns a dedicated `SuiAddress` type — Blake2b-256 hash of a one-byte
  scheme flag (`0x00` for `.ed25519`, `0x01` for `.secp256k1` — selected by
  `SuiPKeySigner.curve`, the `Curve` carried by `WKBlockchain.sui(_:)`)
  followed by the account's raw public key bytes, with no truncation
  (unlike Ethereum, the full 32-byte digest is the address). `SuiAddress`
  conforms to the shared `BlockchainAddress` protocol and has the same
  throwing `init(string:)`/`init(rawBytes:)` shape as `EthereumAddress`,
  except Sui addresses carry no EIP-55-style checksum — casing is never
  validated. There is no Trezor-backed Sui signer yet, since Sui's BCS
  transaction encoding and intent-signing wrapper for a hardware trusted
  screen are a separate, not-yet-speced piece of work (see "Explicitly out
  of scope for now").
- `walletkit-<chain>` (future) — one crate per remaining chain (e.g.
  `walletkit-bitcoin`, `walletkit-solana`, `walletkit-cardano`,
  `walletkit-tron`), following the shape `walletkit-ethereum` and
  `walletkit-sui` establish above. Each backs a software `Signer`
  conformer bound to a `PrivateKey`, with an `Address` type conforming to
  the shared `BlockchainAddress` protocol (string/raw-byte serialization
  plus throwing string/byte parsing) — `Signer.Address` is constrained to
  `BlockchainAddress`, so this isn't optional per chain. A hardware-backed
  conformer per (chain, vendor) — e.g. `EthereumTrezorSigner` — is added
  separately once that chain's device protocol is implemented; see
  "Hardware wallet support" below for why that can't be one shared
  conformer across vendors. Not implemented yet for chains beyond
  Ethereum/Sui.
- `walletkit-<chain>-<vendor>` (future, as needed) — thin crates for
  hardware signing adapters that don't naturally belong inside either the
  chain crate or the vendor crate (e.g. `walletkit-ethereum-trezor`),
  added only if the (chain, vendor) matrix gets unwieldy inside the chain
  crates themselves. Not a phase-1 decision — noted so the seam is
  visible.
- Workspace is structured so `walletkit-ffi` can select which chain and
  vendor crates are compiled in — a GUI app that only needs Bitcoin +
  Ethereum shouldn't have to ship Cardano's CBOR/CSL dependencies, and an
  app with no hardware wallet support shouldn't have to link
  `walletkit-trezor` at all.

## Phase 1 scope: key management

- **Mnemonic** — BIP39 generation (12/15/18/21/24 words) and import,
  wordlist-aware (English at launch, extensible), validated against the
  BIP39 checksum.
- **Seed** — BIP39 seed derivation from mnemonic + optional passphrase
  (25th word). Opaque type; exposes derivation, not raw bytes, on the
  common path.
- **Extended keys / HD derivation** — a single `ExtendedKey` abstraction
  covering both supported schemes:
  - BIP32 for secp256k1-based chains (Bitcoin, Ethereum, Tron, ...).
  - SLIP-0010 for ed25519-based chains (Solana, Sui, ...).
  - Supports path-based derivation (`m/44'/60'/0'/0/0`), single-child
    derivation, and xpub/xprv-style serialization for import/export.
- **DerivationPath / WKBlockchain** — `WKBlockchain` is an enum with one
  case per supported chain (bitcoin, ethereum, tron, solana, cardano,
  sui). It is still just a chain identifier — it carries no
  derivation-path logic of its own, and an account's curve and standard
  `m/purpose'/coin_type'/account'/change/index` path are read directly
  off `Account.curve`/`Account.derivationPath`, not derived from
  `WKBlockchain` — but some cases carry the extra configuration a
  `Signer` needs beyond the identifier itself:
  - `.ethereum(UInt64)` carries the EVM chain ID (1 = mainnet, 11155111 =
    Sepolia, ...) — Ethereum's address derivation doesn't need it, but
    `EthereumPKeySigner`/`EthereumTrezorSigner` use it for EIP-155 replay
    protection, and a signer scoped to one network shouldn't silently
    sign for another.
  - `.sui(Curve)` carries the signature scheme an account uses — Sui,
    unlike Ethereum, supports more than one curve (`.ed25519` is
    standard/default; `.secp256k1` accounts also exist) and encodes
    *which* one directly into the address itself (see `SuiPKeySigner`),
    so the scheme has to travel with the chain identifier rather than
    being implied by it.
  Every other case is a plain, argument-less identifier. `Account` and
  `Signer` are built around `WKBlockchain` either way (callers pass
  `WKBlockchain.ethereum(1)`, `.sui(.ed25519)`, `.bitcoin`, etc. rather than
  a raw string) — a `Signer` conformer fixes its chain's curve internally
  (e.g. `EthereumPKeySigner` always builds a secp256k1 `Account`) and any
  associated configuration for chains that carry one, but takes the
  `derivationPath` its `Account` should carry as an init parameter, since
  only the caller knows which key at which path it's binding the signer
  to.
- **PrivateKey / PublicKey** — curve-tagged key handles. Signing happens
  inside Rust (`privateKey.sign(message:)`); there is intentionally no
  general "give me the raw private key bytes" call on the hot path.

## Hardware wallet support

- **What ships now.** Device discovery, connection/session lifecycle, the
  host-input/confirmation callback model, public-key/address retrieval
  (`HardwareDevice.publicKey`, `HardwareDevice.account`), and — for
  Ethereum — the full device signing conversation
  (`EthereumTrezorSigner.sign(transaction:)`), all over USB on macOS,
  wrapping the Trezor team's own `trezor-client` crate in
  `walletkit-trezor`. iOS compiles the identical public API as a
  `.transportUnavailable`-throwing stub (see "Transport and platform
  constraints" below).
- **How the device conversation works.** Software signing is "sign these
  bytes with this key" — one shape, works for every chain. Hardware
  signing is not: Trezor's wire protocol has a distinct message type per
  chain (`SignTx` for Bitcoin, `EthereumSignTx` for Ethereum, and so on),
  often carrying structured, chain-specific fields rather than a raw
  digest, because the device's trusted screen needs to decode and display
  what it's signing — that's the whole security property of a hardware
  wallet. Every `Signer` conformer still gives *callers* one shared
  `Data`-in/`Data`-out `sign(transaction:)` entry point regardless of
  software vs. hardware, but that doesn't make the underlying problem
  disappear for the hardware-backed conformer itself — it has to decode
  the serialized transaction back into structured fields before it can
  hand them to a device, and re-encode whatever the device signs.
  `EthereumTrezorSigner` is built with exactly that split: `signTx(from:)`
  and `signedTransaction(_:signature:)` are real, Rust-backed, and
  unit-tested against the same vectors as the software path (see "Testing
  strategy"); `sign(transaction:)` composes both around the actual device
  conversation — `walletkit-trezor` hand-rolls the `EthereumSignTx`
  message exchange (rather than using `trezor-client`'s own
  `ethereum_sign_tx` convenience wrapper, which handles button/passphrase
  requests internally but has no hook for a host-entered PIN) so it can
  drive `HardwareDeviceDelegate` for every interaction type, PIN included.
- **One `Signer` protocol, one software and one hardware conformer per
  chain.** A conformer binds to its key source at construction — a
  `PrivateKey` for the software conformer
  (`EthereumPKeySigner`/`SuiPKeySigner`), a connected `HardwareDevice` for
  the hardware one (`EthereumTrezorSigner`) — and exposes the `Account` it
  signs for as a property, built from that same key source. There's no
  shared source-agnostic provider type standing in front of them: GUI code
  that only needs "what's the address" calls `signer.address()`; code that
  signs calls `signer.sign(transaction:)`; which conformer it's holding is
  a construction-time choice, not a runtime branch on the `Account`.
- **Interactive operations need a callback, not just async/throws.**
  Trezor operations can require mid-flight host input (PIN typed against a
  device-displayed matrix, an on-host passphrase) or a physical
  confirmation the user performs on the device itself.
  `HardwareDeviceDelegateFfi` is a genuine UniFFI async foreign trait
  (`#[uniffi::export(foreign, async_runtime = "tokio")]`) — Rust holds a
  handle to a Swift-implemented object and calls into it while an
  operation is in-flight — rather than a single request/response call.
  `walletkit-trezor` hand-rolls the `TrezorResponse` interaction loop
  (button/PIN/passphrase requests) itself rather than using
  `trezor-client`'s own convenience wrappers, which handle button/
  passphrase internally but have no hook for a host-entered PIN. Each
  connected device gets a dedicated OS thread owning its `Trezor` client
  for the device's whole connected lifetime — `TrezorResponse` borrows the
  client mutably, so that loop can never be split across an `.await`; the
  thread calls back into the delegate synchronously via
  `Handle::block_on`, which `walletkit-trezor` only does from its own
  independently-owned Tokio runtime (not whatever runtime UniFFI's own
  async bridge happens to use to poll the exported `async fn`s
  themselves, which is an implementation detail this crate doesn't rely
  on).
- **Transport and platform constraints are real and vendor/model-specific,
  not just an implementation detail:**
  - macOS: USB HID access is practical (IOKit + the appropriate
    sandbox entitlement if sandboxed — the app has no App Sandbox
    capability today, so nothing currently gates this; add
    `com.apple.security.device.usb` if/when it's sandboxed). All current
    Trezor models (One, T, Safe 3, Safe 5, Safe 7) work over USB on macOS,
    via `rusb`/libusb (`walletkit-trezor`'s `trezor-client` dependency).
  - iOS: no generic USB HID access without MFi certification, and Trezor
    devices are not MFi-certified — so USB-connected Trezors cannot sign
    from an iOS app. Trezor Safe 7 adds Bluetooth and is, as of now, the
    only Trezor model with a real iOS signing story. Other models on iOS
    are limited to whatever a companion bridge could offer (viewing
    balances/addresses) — not signing.
  - Practical implication: hardware wallet support should be built and
    tested macOS-first. iOS support should be scoped explicitly per
    device model rather than assumed to follow automatically.
  - `.qrAirGap` is included in `HardwareTransportKind` even though no
    targeted vendor uses it yet, because it's the one transport with no
    iOS/macOS asymmetry (camera access only) — worth keeping in mind if
    iOS parity for hardware wallets matters later.
- **Don't reimplement the device protocol.** Use the Trezor team's own
  `trezor-client` Rust crate for the wire protocol rather than
  hand-rolling protobuf message handling — same reasoning as using
  audited crypto crates instead of custom implementations in
  `walletkit-keys`.

## Known future special case: Cardano

Cardano does not use plain SLIP-0010 — it uses a variant of BIP32-Ed25519
(CIP-1852 paths, extended 96-byte keys, different child-key derivation
math). `WKBlockchain.cardano` is registered now as an identifier case, but
producing a correct `Account.derivationPath` for it requires a dedicated
derivation path inside `walletkit-keys` (or its own crate) before the
Cardano chain client can ship. Called out here so it isn't a surprise
later.

## Security model

- Mnemonic, seed, and private key material are zeroized on drop inside
  Rust (`zeroize` crate or equivalent).
- Sensitive types cross the FFI boundary as opaque UniFFI objects
  (`ExtendedKey`, `PrivateKey`, `Seed`) rather than raw `Data`/`String`
  wherever the operation can be expressed as "do the thing in Rust and
  return the result" instead of "hand me the bytes."
- Explicit raw-export functions (`Seed.exportRaw()`,
  `ExtendedKey.serializedPrivate()`) exist for legitimate backup/import
  flows, are individually named, and are not called implicitly by
  anything else in the library.
- WalletKit never persists keys itself. Storage (Keychain, Secure Enclave
  wrapping, on-disk encrypted files) is entirely the host app's
  responsibility; WalletKit only produces and consumes in-memory material
  and opaque encrypted backup blobs.
- Swift-side callers should treat any `String`/`Data` returned from a raw
  export call as sensitive for the lifetime of the process — Swift value
  types aren't zeroized automatically, so minimize how long they're held
  and avoid logging them.
- Hardware-sourced keys never have raw material cross the FFI boundary at
  all — by construction, not just convention. `HardwareDevice` only ever
  returns public keys and (once implemented) signatures; there is no
  `HardwareDevice.exportPrivateKey()`-shaped call anywhere in the design,
  because the device itself never releases one.

## FFI / bindings strategy

- UniFFI proc-macro exports (`#[uniffi::export]`) rather than `.udl` files,
  so each crate can declare its own exported surface and stay modular as
  chain crates are added.
- Errors surface to Swift as a single `WalletKitError` enum conforming to
  `Error`, generated from a `thiserror`-based Rust error type.
- Object types (`Mnemonic`, `Seed`, `ExtendedKey`, `PrivateKey`,
  `PublicKey`) become UniFFI `interface` types → Swift classes;
  value types (`DerivationPath`, `WKBlockchain`, enums)
  become UniFFI `record`/`enum` types → Swift structs/enums.
- The generated Swift lands in its own module, `WalletKitRust`
  (`Sources/Generated/`, produced by `make walletkit-ffi` — see
  `../Makefile`), linked against the XCFramework it's generated from.
  `WalletKit` (`Sources/Static/`) is a second target holding hand-written
  Swift that `import WalletKitRust` and wraps every UniFFI `interface`
  type (`EthereumAddressFfi`, `PrivateKeyFfi`, ...) behind its own public
  type (`EthereumAddress`, `PrivateKey`, ...) — this is what actually
  keeps the raw `*Ffi` handles out of the API a GUI app sees when it
  `import WalletKit`, since Swift has no per-declaration "internal to
  everyone but this other module" visibility to lean on instead. Plain
  generated value types with no such wrapper (`Curve`, `DerivationPath`,
  `DerivationScheme`, `MnemonicWordCount`, `Wordlist`, `Segment`) are used
  as-is, extended directly where `WalletKit` adds convenience (e.g.
  `DerivationPath.init(string:)`); code that needs to name one of those
  types explicitly needs its own `import WalletKitRust` too, since
  `WalletKit` doesn't re-export it. `WKBlockchain` is the one exception —
  it's a `WalletKit`-side `public typealias` for the generated `Blockchain`
  type, so the app-facing name doesn't collide with the app's own
  `Blockchain` model type.
- Both targets are packaged for the GUI app to consume via Tuist/SPM;
  `WalletKit` is the one it actually depends on and imports.
- Software key derivation/signing is CPU-bound and fast, but
  `HardwareDevice`'s `publicKey`/`account` are `async` to match, so
  callers reading identity don't need two code paths depending on the
  source; `Signer.sign(transaction:)` is `async` uniformly across every
  conformer for the same reason. Hardware operations additionally rely on
  UniFFI's callback-interface
  support (`HardwareDeviceDelegate`) so Rust can call back into Swift
  mid-operation. Future chain clients' networking (RPC calls) fits the
  same async story without a breaking change to how Swift consumes it.

## Explicitly out of scope for now

- Blockchain-specific logic beyond Ethereum (address derivation,
  transaction signing, **transaction building**) and Sui (address
  derivation, transaction signing, **transaction building**):
  address derivation/signing for every chain other than Ethereum/Sui
  (Bitcoin, Tron, Solana, Cardano remain extension points only — see
  `Signer` in Clients/). Fee estimation is **in scope** —
  ``EthereumRPCClient/estimateFee(for:)`` (via EIP-1559 RPC calls) and
  ``SuiGRPCClient/estimateFee(for:)`` (via `simulateTransaction`) are
  both implemented. Transaction building is **in scope** —
  ``EthereumTransactionBuilder`` and ``SuiTransactionBuilder`` implement
  ``BlockchainTransactionBuilderProtocol``; ``AnyBlockchainTransactionBuilder``
  is the String-based type-eraser ready for the app layer.
- Hardware-signing for any chain other than Ethereum — Sui's BCS
  transaction encoding and intent-signing wrapper for a hardware trusted
  screen aren't speced yet either, so there's no `SuiTrezorSigner`.
- Bluetooth/QR-air-gap transports and hardware wallet support on iOS —
  Trezor devices aren't MFi-certified, so iOS has no generic USB HID
  access (see "Transport and platform constraints" above); Trezor Safe 7's
  Bluetooth would be the first real iOS story, not yet built.
- Additional hardware vendors beyond Trezor (Ledger, Keystone, ...) — the
  abstraction is written to accommodate them, but none are being built yet.
- Persistence of any kind (Keychain integration lives in the host app).
- UI/state management (this is a headless library).

## Testing strategy

- Testing happens at two layers, on two sides of the FFI boundary, and both
  are required — neither substitutes for the other:
  - **Rust tests, in the `walletkit-*` crates themselves.** Standard
    `cargo test` unit/integration tests living alongside the code they
    cover (`walletkit-keys`, `walletkit-hardware`, `walletkit-trezor`, and
    each `walletkit-<chain>` crate as it lands). This is where correctness
    of the actual cryptography, derivation math, and protocol handling is
    proven — fast, no FFI/UniFFI/XCFramework build involved, runs on every
    commit.
  - **Swift tests, against the exported WalletKit API.** A Swift test
    target that consumes the generated UniFFI bindings the same way the
    GUI app would — `import WalletKit` and call `Mnemonic`,
    `HardwareDeviceManager`, etc. through their public Swift surface, not
    through Rust directly. (A handful of tests exercise the raw FFI
    boundary itself — e.g. `BigIntTests`' round trip through
    `bigIntEcho` — and additionally `import WalletKitRust` for that; see
    "FFI / bindings strategy" above.) This is what catches bugs the
    Rust-side tests can't see: incorrect UniFFI type mapping, wrong
    Swift-facing defaults/optionality, async/callback-interface behavior
    (`HardwareDeviceDelegate`) actually working across the boundary, and
    `WalletKitError` cases surfacing as the right Swift `Error`. Runs
    against a real built XCFramework, so it's slower and belongs in CI,
    not necessarily on
    every local edit.
- Unit tests against official BIP39 test vectors (multiple languages'
  wordlists as they're added) and BIP32/SLIP-0010 reference test vectors —
  Rust-side, in `walletkit-keys`.
- Cross-check derived keys/addresses against a second independent
  implementation (e.g. a small script using an established library) before
  trusting a derivation path in the GUI.
- Fuzz/property tests around mnemonic parsing and path parsing, since both
  take untrusted string input (user-typed recovery phrases, custom paths) —
  Rust-side.
- Hardware wallet testing can't rely on test vectors the way software
  derivation can — plan for both Trezor's own device emulator (used by the
  `trezor-client`/`trezorlib` test suites) for CI, and periodic manual
  testing against real hardware before any hardware-signing release. The
  emulator-backed cases belong in Rust (`walletkit-trezor`); the
  Swift-side hardware tests focus on the delegate/callback plumbing and
  error mapping rather than re-verifying device protocol correctness.
- Ethereum address derivation is tested against shared vectors in
  `TestVectors/ethereum-address.json` (private key → expected checksummed
  `0x...` address) — both `walletkit-ethereum` (Rust, via `cargo test`) and
  a Swift `EthereumPKeySignerTests` target (against the exported
  `EthereumAddress.init(publicKey:)`) run against the same vector file,
  comparing the derived `EthereumAddress.checksummed` string to each
  vector's expected address, so both sides of the FFI boundary are checked
  against identical expected output, per the two-layer testing approach
  above. The same vector file's expected addresses also double as
  round-trip cases for `EthereumAddress.init(string:)` (should parse back
  to the same `rawBytes`), plus deliberately malformed variants to
  confirm it throws `.invalidAddress` rather than trapping.
- Ethereum transaction signing is tested against shared vectors in
  `TestVectors/ethereum-tx.json` (unsigned RLP signing data + private key →
  expected signed RLP transaction, with EIP-155 `v`/`r`/`s`) — both
  `walletkit-ethereum` (Rust, `cargo test`) and `EthereumPKeySignerTests`
  (Swift, against `EthereumPKeySigner.sign(transaction:)`) run against the
  same vector file, so both sides of the FFI boundary produce
  byte-identical signed output for the same input, per the two-layer
  testing approach above. `EthereumTrezorSignerTests` runs the same
  vectors through `EthereumSignerFfi`'s decode/encode split
  (`signTx(from:)` → a signature computed the same way `signature()`
  would → `signedTransaction(_:signature:)`) whenever a real device is
  connected — this, rather than `sign(transaction:)` itself, is what
  checks against `signedTxHex` byte-for-byte, since a real connected
  device's own key won't match the vector's; a second test calls
  `sign(transaction:)` end to end against the real device instead, which
  can only assert well-formedness. Both skip cleanly (`withKnownIssue`)
  when no device is connected, the same as other device-gated hardware
  tests.
- Sui address derivation has no official published test vectors the way
  Ethereum's BIP39/EIP-155 ones exist — `walletkit-sui`'s Rust tests
  instead independently recompute the expected Blake2b-256 digest via the
  `blake2` crate directly (bypassing `SuiSignerFfi` internals, the same
  "verify against an independent computation" principle as the
  cross-check bullet above) and compare it against `SuiSignerFfi::address()`'s
  output, plus curve-mismatch and cross-scheme-divergence cases.
  `SuiPKeySignerTests` (Swift) runs the ed25519/secp256k1 vectors from the
  same files through `SuiAddress.init(publicKey:curve:)` and
  `SuiPKeySigner.sign(transaction:)`.
