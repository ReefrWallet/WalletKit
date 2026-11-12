//! `HardwareLoggerFfi`: a UniFFI foreign trait the host installs to receive
//! diagnostic messages from the hardware code (off until installed).

use std::sync::Arc;

use walletkit_hardware as hw;

#[uniffi::export(foreign)]
pub trait HardwareLoggerFfi: Send + Sync {
    /// Called with one diagnostic message.
    fn log(&self, message: String);
}

struct LoggerAdapter(Arc<dyn HardwareLoggerFfi>);

impl hw::HardwareLogger for LoggerAdapter {
    fn log(&self, message: String) {
        self.0.log(message);
    }
}

/// Installs `logger` to receive hardware diagnostics, or removes it with `nil`.
#[uniffi::export]
pub fn set_hardware_logger(logger: Option<Arc<dyn HardwareLoggerFfi>>) {
    hw::set_logger(logger.map(|logger| Arc::new(LoggerAdapter(logger)) as Arc<dyn hw::HardwareLogger>));
}
