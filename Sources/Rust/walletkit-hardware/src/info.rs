/// A supported hardware wallet manufacturer.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum HardwareVendor {
    Trezor,
}

/// A physical/logical transport a hardware device can be reached over.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum HardwareTransportKind {
    Usb,
    Bluetooth,
    QrAirGap,
}

/// Static, connection-independent metadata describing a discovered or
/// connected hardware device.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct HardwareDeviceInfo {
    /// A stable identifier for this device. Before a device is connected,
    /// vendor transports may expose no real serial number — a conformer
    /// may synthesize one that is only meaningful within one
    /// scan-then-connect cycle; see `walletkit-trezor`'s `TrezorManager`.
    pub id: String,
    pub vendor: HardwareVendor,
    pub transport: HardwareTransportKind,
    pub model: String,
    pub label: Option<String>,
    pub firmware_version: Option<String>,
    pub needs_firmware_update: bool,
}
