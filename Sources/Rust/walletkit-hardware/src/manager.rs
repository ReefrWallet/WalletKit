use std::sync::Arc;

use async_trait::async_trait;

use crate::{
    delegate::HardwareDeviceDelegate,
    device::HardwareDevice,
    error::HardwareError,
    info::{HardwareDeviceInfo, HardwareTransportKind, HardwareVendor},
};

/// Discovers and connects to hardware wallets.
#[async_trait]
pub trait HardwareDeviceManager: Send + Sync {
    /// Scans for connected/reachable hardware devices.
    ///
    /// - Parameters:
    ///   - vendors: Which manufacturers to look for.
    ///   - transports: Which transports to scan over.
    async fn scan(
        &self,
        vendors: Vec<HardwareVendor>,
        transports: Vec<HardwareTransportKind>,
    ) -> Result<Vec<HardwareDeviceInfo>, HardwareError>;

    /// Connects to a previously discovered device.
    ///
    /// - Parameters:
    ///   - info: The device to connect to, as returned by `scan`.
    ///   - delegate: The delegate to relay input/confirmation requests and
    ///     disconnection events to.
    async fn connect(
        &self,
        info: HardwareDeviceInfo,
        delegate: Arc<dyn HardwareDeviceDelegate>,
    ) -> Result<Arc<dyn HardwareDevice>, HardwareError>;
}
