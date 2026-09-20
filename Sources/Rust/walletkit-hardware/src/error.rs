/// Errors a `HardwareDeviceManager`/`HardwareDevice` conformer can raise.
/// `walletkit-ffi` maps every variant here 1:1 onto the corresponding
/// hardware-wallet case of `WalletKitErrorFfi`.
#[derive(Debug, Clone, PartialEq, Eq, thiserror::Error)]
pub enum HardwareError {
    #[error("device not found")]
    NotFound,
    #[error("device disconnected")]
    Disconnected,
    #[error("device locked")]
    Locked,
    #[error("device busy")]
    Busy,
    #[error("user rejected on device")]
    UserRejectedOnDevice,
    #[error("user cancelled")]
    UserCancelled,
    #[error("transport unavailable: {reason}")]
    TransportUnavailable { reason: String },
    #[error("unsupported device: {reason}")]
    UnsupportedDevice { reason: String },
    #[error("firmware outdated: minimum version {minimum_version}")]
    FirmwareOutdated { minimum_version: String },
    #[error("signing failed: {reason}")]
    SigningFailed { reason: String },
}
