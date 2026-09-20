use std::sync::Arc;

use walletkit_hardware::HardwareDeviceManager as _;
use walletkit_trezor::TrezorManager;

use crate::errors::WalletKitErrorFfi;

use super::{
    delegate::{DelegateAdapter, HardwareDeviceDelegateFfi},
    device::HardwareDeviceFfi,
    types::{HardwareDeviceInfoFfi, HardwareTransportKindFfi, HardwareVendorFfi},
};

/// Discovers and connects to hardware wallets. Trezor is the only vendor
/// wired up today (over USB, macOS only — see `Docs/Overview.md`'s
/// "Transport and platform constraints"); other vendors/transports would
/// be dispatched from here as they're added, without changing this type's
/// exported shape.
#[derive(uniffi::Object)]
pub struct HardwareDeviceManagerFfi {
    trezor: TrezorManager,
}

#[uniffi::export(async_runtime = "tokio")]
impl HardwareDeviceManagerFfi {
    #[uniffi::constructor]
    pub fn new() -> HardwareDeviceManagerFfi {
        HardwareDeviceManagerFfi { trezor: TrezorManager::new() }
    }

    /// Scans for connected/reachable hardware devices.
    ///
    /// Throws `.transportUnavailable` if `transports` is empty, or if USB
    /// isn't supported on this platform (see `Docs/Overview.md`).
    pub async fn scan(
        &self,
        vendors: Vec<HardwareVendorFfi>,
        transports: Vec<HardwareTransportKindFfi>,
    ) -> Result<Vec<HardwareDeviceInfoFfi>, WalletKitErrorFfi> {
        if transports.is_empty() {
            return Err(WalletKitErrorFfi::TransportUnavailable { reason: "no transports requested".to_string() });
        }
        let infos = self
            .trezor
            .scan(vendors.into_iter().map(Into::into).collect(), transports.into_iter().map(Into::into).collect())
            .await?;
        Ok(infos.into_iter().map(Into::into).collect())
    }

    /// Connects to a previously discovered device.
    ///
    /// Throws `.deviceNotFound` if `info` doesn't match a device from a
    /// preceding `scan` call, or other hardware-wallet `WalletKitError`
    /// cases if the connection handshake fails.
    pub async fn connect(
        &self,
        info: HardwareDeviceInfoFfi,
        delegate: Arc<dyn HardwareDeviceDelegateFfi>,
    ) -> Result<Arc<HardwareDeviceFfi>, WalletKitErrorFfi> {
        let device = self.trezor.connect(info.into(), Arc::new(DelegateAdapter(delegate))).await?;
        Ok(Arc::new(HardwareDeviceFfi { inner: device }))
    }
}
