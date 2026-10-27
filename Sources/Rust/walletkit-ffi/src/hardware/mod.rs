//! UniFFI export layer for hardware wallet support. Wraps
//! `walletkit-hardware`'s vendor-agnostic traits/types and
//! `walletkit-trezor`'s Trezor implementation behind `#[uniffi::export]`,
//! including the foreign-trait callback interface
//! (`HardwareDeviceDelegateFfi`) so Rust can call back into Swift
//! mid-operation for PIN/passphrase/button prompts. See
//! `Walletkit/Docs/Overview.md`'s "Hardware wallet support".

mod cardano_dapp;
mod delegate;
mod device;
mod manager;
mod types;

pub use delegate::HardwareDeviceDelegateFfi;
pub use device::{CardanoInputFfi, CardanoOutputFfi, CardanoSignTxFfi, HardwareCardanoAssetFfi, tron_raw_data, HardwareDeviceFfi};
pub use manager::HardwareDeviceManagerFfi;
pub use types::{
    HardwareButtonRequestFfi, HardwareDeviceInfoFfi, HardwareInputRequestFfi, HardwareTransportKindFfi, HardwareVendorFfi,
};
