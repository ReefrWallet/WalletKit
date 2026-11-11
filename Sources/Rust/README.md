# WalletKit — Rust workspace

- `walletkit-ffi` — the UniFFI bridge for key management, chain-specific
  primitives for Aptos, Bitcoin, Cardano, Ethereum/EVM, Solana, and Sui,
  plus Tron transaction encoding and Trezor integration. Network clients
  live in Swift.
- `walletkit-hardware` — shared hardware wallet traits and types.
- `walletkit-trezor` — Trezor USB support on macOS via `trezor-client`.
  On other platforms, discovery returns an empty list and connections return
  `TransportUnavailable`.

## Rust development

Build and test all three crates for the host platform from `Sources/Rust`.

```sh
cargo build --workspace --locked
cargo test --workspace --locked
```

## Build the XCFramework and Swift bindings

On macOS, install Xcode and use `rustup` to install Rust. Run from the WalletKit root.

```sh
make walletkit-ffi
```

The [Makefile](../../Makefile) builds the macOS, iOS device, and iOS simulator
slices into `Frameworks/WalletKit.xcframework` and generates the Swift bindings
in `Sources/Generated/Bindings/`.

## Build and test WalletKit

Install the prerequisites in the [WalletKit README](../../README.md#requirements)
and the [CI workflow](../../.github/workflows/ci.yml). From the WalletKit root,
initialize the Sui protobuf submodule and install the pinned tools.

```sh
git submodule update --init --recursive
mise install
```

Run `make spm` to build the Swift package or `make test` to run the Rust FFI and
Swift test suites. Both targets generate the XCFramework, Swift bindings, and
Sui gRPC sources as needed. Local test runs also provision node tools for Aptos,
Bitcoin, and Solana.
