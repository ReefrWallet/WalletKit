//! The real Trezor implementation, wrapping the Trezor team's own
//! `trezor-client` crate over USB. See the crate-level doc comment for
//! why this is macOS-only.

mod device;
mod error;
mod interaction;
mod manager;
mod runtime;
mod worker;

pub use device::TrezorDevice;
pub use manager::TrezorManager;
