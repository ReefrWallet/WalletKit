use async_trait::async_trait;

/// A piece of input a hardware device is asking the user to provide.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum HardwareInputRequest {
    /// The device wants its PIN entered. `attempt` is the 1-based attempt
    /// number for this unlock session.
    Pin { attempt: u32 },

    /// The device wants a BIP39 passphrase (the "25th word") entered.
    Passphrase,
}

/// A physical confirmation the device is waiting for the user to perform
/// on its own screen/buttons.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum HardwareButtonRequest {
    ConfirmAddress,
    ConfirmPublicKey,
    ConfirmTransaction,
    Other { description: String },
}

/// Callbacks a `HardwareDevice` uses to relay user-interaction requests and
/// lifecycle events back to the host app. One delegate is bound to one
/// device at connection time (`HardwareDeviceManager::connect`), so these
/// methods carry no device identity of their own — the caller already
/// knows which device it's driving.
#[async_trait]
pub trait HardwareDeviceDelegate: Send + Sync {
    /// Called when the device needs the user to provide a piece of input
    /// (a PIN or passphrase). Returns the user-provided value, or `None`
    /// if the user cancelled.
    async fn needs_input(&self, request: HardwareInputRequest) -> Option<String>;

    /// Called when the device is waiting for the user to physically
    /// confirm something on the device itself.
    async fn waiting_for_confirmation(&self, request: HardwareButtonRequest);

    /// Called when the device disconnects, whether initiated by the app or
    /// externally (e.g. the user unplugged it).
    async fn did_disconnect(&self);
}
