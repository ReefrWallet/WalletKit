//! Vendor-agnostic hardware wallet plumbing: the `HardwareDevice`/
//! `HardwareDeviceManager`/`HardwareDeviceDelegate` traits, transport and
//! vendor enumeration, and the async delegate mechanism for host-side
//! PIN/passphrase/button prompts. Defines the contract; carries no vendor
//! protocol code itself — `walletkit-trezor` implements these traits for
//! Trezor devices. See `Walletkit/Docs/Overview.md`'s "Hardware wallet
//! support".

mod delegate;
mod device;
mod error;
mod info;
mod manager;
mod path;

pub use delegate::{HardwareButtonRequest, HardwareDeviceDelegate, HardwareInputRequest};
pub use device::{
    EthereumEIP1559Signature, EthereumEIP1559TxFields, EthereumSignature, EthereumTxFields,
    HardwareCurve, HardwareDevice,
};
pub use error::HardwareError;
pub use info::{HardwareDeviceInfo, HardwareTransportKind, HardwareVendor};
pub use manager::HardwareDeviceManager;
pub use path::HardwarePathSegment;
