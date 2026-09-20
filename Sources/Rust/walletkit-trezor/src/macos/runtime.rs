use std::sync::OnceLock;

use tokio::runtime::{Handle, Runtime};

/// A `Handle` to a Tokio runtime this crate owns and manages itself,
/// independent of whatever mechanism UniFFI's own async bridge uses to
/// poll the `async fn`s this crate's callers export. Every `DeviceWorker`
/// needs a real runtime `Handle` so its dedicated thread can call back
/// into the (async, Swift-implemented) delegate via `Handle::block_on` —
/// relying on an ambient "current" runtime supplied by the FFI caller
/// would make that depend on implementation details (does UniFFI's
/// `async_runtime = "tokio"` actually run our future on a full Tokio
/// runtime, or just bridge individual tokio APIs via `async-compat`?) this
/// crate has no control over and shouldn't have to reason about.
///
/// Multi-threaded (not `new_current_thread`): multiple connected devices
/// each drive their own worker thread, and those threads' `block_on` calls
/// against this shared runtime can happen concurrently — a current-thread
/// runtime only supports one `block_on` caller at a time.
pub(super) fn handle() -> Handle {
    static RUNTIME: OnceLock<Runtime> = OnceLock::new();
    RUNTIME.get_or_init(|| Runtime::new().expect("failed to start walletkit-trezor's Tokio runtime")).handle().clone()
}
