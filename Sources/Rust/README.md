# WalletKit — Rust workspace

Three crates:

- `walletkit-ffi` — the UniFFI export layer covering software key
  management (BIP39 mnemonics, BIP32/SLIP-0010 derivation), Ethereum/Sui
  chain clients, and the hardware-wallet FFI surface (`hardware/`).
- `walletkit-hardware` — vendor-agnostic hardware wallet traits/types, no
  vendor protocol code.
- `walletkit-trezor` — implements those traits for Trezor over USB,
  wrapping the Trezor team's own `trezor-client` crate. Only builds real
  USB support on macOS (Trezor devices aren't MFi-certified, so iOS has no
  generic USB HID access); other targets compile the same public API as a
  transport-unavailable stub.

See `../Docs/Overview.md` for the target architecture and
`../Docs/Design Specification/` for the Swift API this crate backs.

For the full macOS + iOS (device + simulator) XCFramework build, use the
top-level `../Makefile` (`make walletkit-ffi`, `make test`, `make all`,
`make clean`) rather than the manual commands below — those are still
useful for quick host-only iteration while developing, but the Makefile is
what actually produces something Xcode can link against.

## Build (host-only, for local iteration)

```sh
cargo build --workspace
```

## Test

Rust-side tests live alongside the code they cover, per
`../Docs/Overview.md`'s testing strategy:

```sh
cargo test --workspace
```

Hardware-wallet tests here are unit tests over pure logic (path/error
mapping, byte encoding) — they don't need a connected device. Tests that
do need one live on the Swift side (`Tests/Hardware/`,
`Tests/Blockchains/EthereumTrezorSignerTests.swift`), gated with
`withKnownIssue` so they skip cleanly in CI.

## Generate Swift bindings

UniFFI's recommended "library mode" generates bindings straight from the
compiled library, so build first, then run the `uniffi-bindgen` binary
declared in `walletkit-ffi/Cargo.toml`:

```sh
cd walletkit-ffi
cargo build
cargo run --features cli --bin uniffi-bindgen -- generate \
    --library target/debug/libwalletkit_ffi.dylib \
    --language swift \
    --out-dir ../generated/swift
```

(`.dylib` on macOS; adjust the path/extension for other platforms.) This
generates the real `WalletKit.swift`/`.h`/`.modulemap` files — a separate
artifact from the hand-written API spec under
`Docs/Design Specification/`, which describes the *target* surface rather
than being compiled itself.
