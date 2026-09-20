use std::sync::Arc;

use trezor_client::{client::common::TrezorResponse, TrezorMessage};
use walletkit_hardware::{HardwareButtonRequest, HardwareDeviceDelegate, HardwareError, HardwareInputRequest};

use super::error::map_trezor_error;

/// Drives a `TrezorResponse` interaction loop to completion, relaying
/// button/PIN/passphrase requests to `delegate` as they arrive.
///
/// This exists because `trezor-client`'s own convenience wrappers
/// (`ethereum_sign_tx`, `ethereum_get_address`, ...) handle button and
/// passphrase requests internally but simply error out on a
/// `PinMatrixRequest` — there is no hook for host-entered PIN. Every call
/// site in this crate therefore uses the raw `Trezor::call`-returning
/// methods (`get_public_key`, or a hand-rolled `EthereumSignTx` exchange)
/// and drives the loop here instead.
///
/// Must run entirely on the same thread that owns the `Trezor` client —
/// `TrezorResponse` borrows it mutably, so this can never be split across
/// an `.await`. When it needs the delegate, it calls back into the async
/// world via `runtime.block_on(..)`, which is only safe because the
/// caller is a plain `std::thread`, never a tokio worker thread (see
/// `super::worker`).
pub(super) fn drive_interaction<T, R: TrezorMessage>(
    result: trezor_client::Result<TrezorResponse<'_, T, R>>,
    delegate: &Arc<dyn HardwareDeviceDelegate>,
    runtime: &tokio::runtime::Handle,
    button_kind: &HardwareButtonRequest,
) -> Result<T, HardwareError> {
    let mut resp = result.map_err(map_trezor_error)?;
    let mut pin_attempt: u32 = 0;
    loop {
        resp = match resp {
            TrezorResponse::Ok(value) => return Ok(value),
            TrezorResponse::Failure(failure) => return Err(super::error::map_failure(&failure)),
            TrezorResponse::ButtonRequest(req) => {
                runtime.block_on(delegate.waiting_for_confirmation(button_kind.clone()));
                req.ack().map_err(map_trezor_error)?
            }
            TrezorResponse::PinMatrixRequest(req) => {
                pin_attempt += 1;
                let pin = runtime.block_on(delegate.needs_input(HardwareInputRequest::Pin { attempt: pin_attempt }));
                match pin {
                    Some(pin) => req.ack_pin(pin).map_err(map_trezor_error)?,
                    None => return Err(HardwareError::UserCancelled),
                }
            }
            TrezorResponse::PassphraseRequest(req) => {
                if req.on_device() {
                    // The device itself can accept passphrase entry on its
                    // own trusted screen; let it, without prompting the host.
                    req.ack(true).map_err(map_trezor_error)?
                } else {
                    let passphrase = runtime.block_on(delegate.needs_input(HardwareInputRequest::Passphrase));
                    match passphrase {
                        Some(passphrase) => req.ack_passphrase(passphrase).map_err(map_trezor_error)?,
                        None => return Err(HardwareError::UserCancelled),
                    }
                }
            }
        };
    }
}
