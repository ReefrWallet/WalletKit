//! Trezor support for `walletkit-hardware`'s traits, over USB.
//!
//! The real implementation (`macos`) wraps the Trezor team's own
//! `trezor-client` crate, which talks to the device over `rusb`/libusb.
//! That only builds on macOS — see `Docs/Overview.md`'s "Transport and
//! platform constraints": Trezor devices aren't MFi-certified, so iOS has
//! no generic USB HID access. Every other target compiles `unsupported`
//! instead, which exposes the exact same public API (`TrezorManager`,
//! `TrezorDevice`) but every operation resolves to
//! `HardwareError::TransportUnavailable`. This keeps `walletkit-ffi`'s
//! exported surface identical across platforms, which matters because its
//! Swift bindings are generated once (from the macOS build) and then
//! linked against every platform's slice of the XCFramework.

#[cfg(target_os = "macos")]
mod macos;
#[cfg(target_os = "macos")]
pub use macos::{TrezorDevice, TrezorManager};

#[cfg(not(target_os = "macos"))]
mod unsupported;
#[cfg(not(target_os = "macos"))]
pub use unsupported::{TrezorDevice, TrezorManager};
