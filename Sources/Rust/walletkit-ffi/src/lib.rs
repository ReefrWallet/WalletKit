//! walletkit-ffi
//!
//! UniFFI export layer for WalletKit. See `Walletkit/Docs/Overview.md` for
//! the target architecture and `Walletkit/Docs/Design Specification/` for
//! the Swift API this crate backs.
//!
//! Module layout mirrors the Swift design spec's folders 1:1
//! (`core` is reserved by the standard library, so the Swift `Core/`
//! folder maps to `common` here):
//!
//!   errors/         WalletKitError
//!   common/         CurveFfi, DerivationScheme, WordlistFfi, MnemonicWordCountFfi,
//!                   BlockchainFfi, DerivationPathFfi, BigIntFfi
//!   keys/           Mnemonic, Seed, ExtendedKey, PublicKey, PrivateKey
//!   accounts/       KeySource, Account — not implemented yet
//!   hardware/       HardwareVendorFfi, HardwareTransportKindFfi,
//!                   HardwareDeviceInfoFfi, HardwareDeviceFfi,
//!                   HardwareDeviceManagerFfi, HardwareDeviceDelegateFfi —
//!                   Trezor over USB (macOS only)
//!   blockchain_clients/  Chain-specific address, transaction, and signing
//!                   primitives for the Swift clients. Tron transaction
//!                   encoding lives alongside its Trezor bridge in hardware/.

uniffi::setup_scaffolding!();

mod accounts;
pub mod blockchain_clients;
pub mod common;
pub mod errors;
pub mod hardware;
pub mod keys;
#[cfg(test)]
mod test_vectors;
