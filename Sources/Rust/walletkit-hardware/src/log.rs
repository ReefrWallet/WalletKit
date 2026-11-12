//! Opt-in diagnostic logging for hardware code. Off until the host
//! installs a logger, so the message closures cost nothing by default.

use std::sync::{Arc, RwLock};

/// Receives diagnostic messages. Implemented by the host app.
pub trait HardwareLogger: Send + Sync {
    fn log(&self, message: String);
}

static LOGGER: RwLock<Option<Arc<dyn HardwareLogger>>> = RwLock::new(None);

/// Installs `logger`, or turns logging off with `None`.
pub fn set_logger(logger: Option<Arc<dyn HardwareLogger>>) {
    if let Ok(mut slot) = LOGGER.write() {
        *slot = logger;
    }
}

/// Sends `message()` to the installed logger; does nothing if there is none.
pub fn log(message: impl FnOnce() -> String) {
    let logger = LOGGER.read().ok().and_then(|slot| slot.clone());
    if let Some(logger) = logger {
        logger.log(message());
    }
}

/// `hw_log!("format {}", args)`: logs only when a logger is installed.
#[macro_export]
macro_rules! hw_log {
    ($($arg:tt)*) => {
        $crate::log(|| format!($($arg)*))
    };
}
