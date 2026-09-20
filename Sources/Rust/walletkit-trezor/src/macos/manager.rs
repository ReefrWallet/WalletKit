use std::{
    collections::HashMap,
    sync::{Arc, Mutex},
};

use async_trait::async_trait;
use trezor_client::AvailableDevice;
use walletkit_hardware::{
    HardwareDevice as HardwareDeviceTrait, HardwareDeviceDelegate, HardwareDeviceInfo,
    HardwareDeviceManager as HardwareDeviceManagerTrait, HardwareError, HardwareTransportKind, HardwareVendor,
};

use super::device::TrezorDevice;

/// Discovers and connects to Trezor devices over USB.
///
/// `trezor-client` exposes no stable serial number for a device before
/// it's connected (`AvailableDevice` carries only its `model` and whether
/// it's in debug mode), and `AvailableDevice::connect` consumes the value.
/// So `scan` caches the `Vec<AvailableDevice>` it found, and
/// `HardwareDeviceInfo.id` is synthesized from each entry's position —
/// stable only within one scan-then-connect cycle, not across scans. Once
/// actually connected, `TrezorDevice::info()` carries the device's real
/// `device_id` read from its `Features` instead.
///
/// `connect` also tracks currently-connected devices and hands back the
/// existing one for a repeat call rather than opening a second, unrelated
/// USB session to the same physical device — `trezor-client`/libusb don't
/// protect against two independent handles claiming the same interface,
/// and racing on the same interrupt endpoint corrupts both conversations
/// (a stale response meant for one session gets delivered to the other's
/// read instead). A caller that never explicitly disconnects between
/// operations — the common case — would otherwise leak a new session on
/// every call.
#[derive(Default)]
pub struct TrezorManager {
    scanned: Mutex<Vec<AvailableDevice>>,
    connected: Mutex<HashMap<String, Arc<dyn HardwareDeviceTrait>>>,
}

impl TrezorManager {
    pub fn new() -> Self {
        Self { scanned: Mutex::new(Vec::new()), connected: Mutex::new(HashMap::new()) }
    }
}

fn synthetic_id(index: usize, model: trezor_client::Model, debug: bool) -> String {
    format!("trezor-usb-{index}-{model:?}-{debug}")
}

#[async_trait]
impl HardwareDeviceManagerTrait for TrezorManager {
    async fn scan(
        &self,
        vendors: Vec<HardwareVendor>,
        transports: Vec<HardwareTransportKind>,
    ) -> Result<Vec<HardwareDeviceInfo>, HardwareError> {
        if !vendors.contains(&HardwareVendor::Trezor) || !transports.contains(&HardwareTransportKind::Usb) {
            return Ok(Vec::new());
        }

        // A plain thread + oneshot rather than `tokio::task::spawn_blocking`,
        // for the same reason `DeviceWorker` doesn't rely on tokio's
        // blocking pool either — see `runtime.rs`'s doc comment. A oneshot
        // channel's `Receiver::await` needs no ambient runtime to poll
        // correctly, unlike `spawn_blocking`, which submits to whichever
        // runtime `Handle::current()` resolves to at the call site.
        let (tx, rx) = tokio::sync::oneshot::channel();
        std::thread::spawn(move || {
            let _ = tx.send(trezor_client::find_devices(false));
        });
        let devices = rx.await.map_err(|_| HardwareError::TransportUnavailable {
            reason: "device scan thread terminated unexpectedly".to_string(),
        })?;

        let infos = devices
            .iter()
            .enumerate()
            .map(|(index, device)| HardwareDeviceInfo {
                id: synthetic_id(index, device.model, device.debug),
                vendor: HardwareVendor::Trezor,
                transport: HardwareTransportKind::Usb,
                model: device.model.as_str().to_string(),
                label: None,
                firmware_version: None,
                needs_firmware_update: false,
            })
            .collect();

        *self.scanned.lock().expect("scanned mutex poisoned") = devices;
        Ok(infos)
    }

    async fn connect(
        &self,
        info: HardwareDeviceInfo,
        delegate: Arc<dyn HardwareDeviceDelegate>,
    ) -> Result<Arc<dyn HardwareDeviceTrait>, HardwareError> {
        if info.vendor != HardwareVendor::Trezor {
            return Err(HardwareError::NotFound);
        }

        {
            let mut connected = self.connected.lock().expect("connected mutex poisoned");
            if let Some(existing) = connected.get(&info.id) {
                if existing.is_connected() {
                    return Ok(existing.clone());
                }
                connected.remove(&info.id);
            }
        }

        let available = {
            let mut scanned = self.scanned.lock().expect("scanned mutex poisoned");
            let index = scanned
                .iter()
                .enumerate()
                .find(|(index, device)| synthetic_id(*index, device.model, device.debug) == info.id)
                .map(|(index, _)| index)
                .ok_or(HardwareError::NotFound)?;
            scanned.remove(index)
        };

        let device_id = info.id.clone();
        let device = TrezorDevice::connect(available, info, delegate).await?;
        self.connected.lock().expect("connected mutex poisoned").insert(device_id, device.clone());
        Ok(device)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn synthetic_id_is_stable_for_the_same_index_model_and_debug_flag() {
        assert_eq!(
            synthetic_id(0, trezor_client::Model::Trezor, false),
            synthetic_id(0, trezor_client::Model::Trezor, false)
        );
    }

    #[test]
    fn synthetic_id_differs_by_index_model_or_debug_flag() {
        let base = synthetic_id(0, trezor_client::Model::Trezor, false);
        assert_ne!(base, synthetic_id(1, trezor_client::Model::Trezor, false));
        assert_ne!(base, synthetic_id(0, trezor_client::Model::TrezorLegacy, false));
        assert_ne!(base, synthetic_id(0, trezor_client::Model::Trezor, true));
    }
}
