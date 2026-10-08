//! `HardwareDeviceDelegateFfi`: a UniFFI foreign trait — Rust holds a
//! handle to a Swift-implemented object and calls into it while a device
//! operation is in-flight, for PIN/passphrase/button prompts. See
//! `Walletkit/Docs/Overview.md`'s "Interactive operations need a
//! callback, not just async/throws".

use std::sync::Arc;

use async_trait::async_trait;
use walletkit_hardware as hw;

use super::types::{HardwareButtonRequestFfi, HardwareInputRequestFfi};

#[uniffi::export(foreign, async_runtime = "tokio")]
#[async_trait]
pub trait HardwareDeviceDelegateFfi: Send + Sync {
    /// Called when the device needs the user to provide a piece of input
    /// (a PIN or passphrase). Returns the user-provided value, or `None`
    /// if the user cancelled.
    async fn needs_input(&self, request: HardwareInputRequestFfi) -> Option<String>;

    /// Called when the device is waiting for the user to physically
    /// confirm something on the device itself.
    async fn waiting_for_confirmation(&self, request: HardwareButtonRequestFfi);

    /// Called when the device disconnects, whether initiated by the app
    /// or externally (e.g. the user unplugged it).
    async fn did_disconnect(&self);
}

/// Adapts a Swift-implemented `HardwareDeviceDelegateFfi` into the plain
/// Rust `walletkit_hardware::HardwareDeviceDelegate` that
/// `walletkit-trezor` (and any future vendor crate) actually calls,
/// converting the FFI-facing request types on the way through.
pub(super) struct DelegateAdapter(pub Arc<dyn HardwareDeviceDelegateFfi>);

#[async_trait]
impl hw::HardwareDeviceDelegate for DelegateAdapter {
    async fn needs_input(&self, request: hw::HardwareInputRequest) -> Option<String> {
        self.0.needs_input(request.into()).await
    }

    async fn waiting_for_confirmation(&self, request: hw::HardwareButtonRequest) {
        self.0.waiting_for_confirmation(request.into()).await
    }

    async fn did_disconnect(&self) {
        self.0.did_disconnect().await
    }
}
