use std::{
    panic::{catch_unwind, AssertUnwindSafe},
    sync::{
        atomic::{AtomicBool, Ordering},
        mpsc, Arc, Mutex,
    },
};

use tokio::sync::oneshot;
use trezor_client::{protos, AvailableDevice, Trezor};
use walletkit_hardware::{
    CardanoDappTxRequest, CardanoDappTxSignature, CardanoMessageRequest, CardanoMessageSignature,
    CardanoTxFields, CardanoWitness, EthereumEIP1559Signature, EthereumEIP1559TxFields, EthereumSignature, EthereumTxFields,
    EthereumTypedDataFields, HardwareBitcoinNetwork, HardwareButtonRequest, HardwareDeviceDelegate, HardwareError,
    HardwarePathSegment, SolanaTxFields, TronTxFields, hw_log,
};

use super::{error::map_trezor_error, interaction::drive_interaction};

/// What a connected device's `Features` told us, refined from the
/// synthetic scan-time `HardwareDeviceInfo` once we actually know it.
pub(super) struct ConnectedFeatures {
    pub device_id: Option<String>,
    pub label: Option<String>,
    pub model_name: Option<String>,
    pub firmware_version: Option<String>,
}

enum Command {
    PublicKey { path: Vec<HardwarePathSegment>, reply: oneshot::Sender<Result<Vec<u8>, HardwareError>> },
    EthereumSignTx {
        path: Vec<HardwarePathSegment>,
        fields: EthereumTxFields,
        reply: oneshot::Sender<Result<EthereumSignature, HardwareError>>,
    },
    EthereumSignTxEip1559 {
        path: Vec<HardwarePathSegment>,
        fields: EthereumEIP1559TxFields,
        reply: oneshot::Sender<Result<EthereumEIP1559Signature, HardwareError>>,
    },
    EthereumSignMessage {
        path: Vec<HardwarePathSegment>,
        message: Vec<u8>,
        reply: oneshot::Sender<Result<EthereumSignature, HardwareError>>,
    },
    EthereumSignTypedData {
        path: Vec<HardwarePathSegment>,
        fields: EthereumTypedDataFields,
        reply: oneshot::Sender<Result<EthereumSignature, HardwareError>>,
    },
    TronSignTx {
        path: Vec<HardwarePathSegment>,
        fields: TronTxFields,
        reply: oneshot::Sender<Result<Vec<u8>, HardwareError>>,
    },
    SolanaPublicKey { path: Vec<HardwarePathSegment>, reply: oneshot::Sender<Result<Vec<u8>, HardwareError>> },
    SolanaSignTx {
        path: Vec<HardwarePathSegment>,
        fields: SolanaTxFields,
        reply: oneshot::Sender<Result<Vec<u8>, HardwareError>>,
    },
    SolanaSignMessage {
        path: Vec<HardwarePathSegment>,
        message: String,
        signers: Vec<Vec<u8>>,
        reply: oneshot::Sender<Result<Vec<u8>, HardwareError>>,
    },
    CardanoXpub { path: Vec<HardwarePathSegment>, reply: oneshot::Sender<Result<String, HardwareError>> },
    CardanoSignTx { fields: CardanoTxFields, reply: oneshot::Sender<Result<Vec<CardanoWitness>, HardwareError>> },
    CardanoSignDappTx { request: CardanoDappTxRequest, reply: oneshot::Sender<Result<CardanoDappTxSignature, HardwareError>> },
    CardanoSignMessage { request: CardanoMessageRequest, reply: oneshot::Sender<Result<CardanoMessageSignature, HardwareError>> },
    BitcoinXpub {
        path: Vec<HardwarePathSegment>,
        reply: oneshot::Sender<Result<String, HardwareError>>,
    },
    BitcoinSignPsbt {
        psbt: Vec<u8>,
        network: HardwareBitcoinNetwork,
        reply: oneshot::Sender<Result<Vec<u8>, HardwareError>>,
    },
    Disconnect,
}

impl Command {
    fn name(&self) -> &'static str {
        match self {
            Command::PublicKey { .. } => "PublicKey",
            Command::EthereumSignTx { .. } => "EthereumSignTx",
            Command::EthereumSignTxEip1559 { .. } => "EthereumSignTxEip1559",
            Command::EthereumSignMessage { .. } => "EthereumSignMessage",
            Command::EthereumSignTypedData { .. } => "EthereumSignTypedData",
            Command::TronSignTx { .. } => "TronSignTx",
            Command::SolanaPublicKey { .. } => "SolanaPublicKey",
            Command::SolanaSignTx { .. } => "SolanaSignTx",
            Command::SolanaSignMessage { .. } => "SolanaSignMessage",
            Command::CardanoXpub { .. } => "CardanoXpub",
            Command::CardanoSignTx { .. } => "CardanoSignTx",
            Command::CardanoSignDappTx { .. } => "CardanoSignDappTx",
            Command::CardanoSignMessage { .. } => "CardanoSignMessage",
            Command::BitcoinXpub { .. } => "BitcoinXpub",
            Command::BitcoinSignPsbt { .. } => "BitcoinSignPsbt",
            Command::Disconnect => "Disconnect",
        }
    }
}

/// Owns the device conversation on a dedicated OS thread, for as long as
/// the device stays connected.
///
/// A `Trezor` client (and the `TrezorResponse` interaction loop that comes
/// with it) is not `Send`-friendly across `.await` points — `TrezorResponse`
/// borrows the client mutably, so the loop has to run start-to-finish
/// without yielding. Rather than fight that, this hands the client to a
/// plain `std::thread` that owns it exclusively for its whole life:
/// exported `async` methods on `TrezorDevice` just send a `Command` and
/// await a `oneshot` reply. The blocking device I/O, including the
/// interaction loop's calls back into the (async) delegate via
/// `runtime.block_on`, all happen on the worker thread — safe specifically
/// because a hand-spawned `std::thread` is never a tokio runtime worker
/// thread, unlike a `spawn_blocking` task.
pub(super) struct DeviceWorker {
    command_tx: mpsc::Sender<Command>,
    connected: Arc<AtomicBool>,
    /// Why the worker thread died, if it panicked.
    failure: Arc<Mutex<Option<String>>>,
}

impl DeviceWorker {
    /// Spawns the worker thread, which connects to `available` and
    /// performs the initial `Initialize` handshake before this function
    /// returns. `setup_rx` resolves once that finishes (Ok with the
    /// device's reported `Features`, or the connect/handshake error) —
    /// the thread then goes on to serve `Command`s regardless of the
    /// caller ever observing that result.
    pub(super) fn spawn(
        available: AvailableDevice,
        delegate: Arc<dyn HardwareDeviceDelegate>,
        runtime: tokio::runtime::Handle,
    ) -> (DeviceWorker, oneshot::Receiver<Result<ConnectedFeatures, HardwareError>>) {
        let (command_tx, command_rx) = mpsc::channel::<Command>();
        let (setup_tx, setup_rx) = oneshot::channel();
        let connected = Arc::new(AtomicBool::new(true));
        let connected_for_thread = connected.clone();
        let failure = Arc::new(Mutex::new(None));
        let failure_for_thread = failure.clone();

        std::thread::spawn(move || {
            let _connected_guard = ConnectedGuard(connected_for_thread.clone());
            hw_log!("worker: connecting to {available}");
            drain_stale_replies(&available);

            let mut trezor = match available.connect().map_err(map_trezor_error) {
                Ok(trezor) => trezor,
                Err(err) => {
                    hw_log!("worker: connect failed: {err:?}");
                    let _ = setup_tx.send(Err(err));
                    connected_for_thread.store(false, Ordering::SeqCst);
                    return;
                }
            };

            let setup_result = drive_interaction(
                trezor.initialize(None),
                &delegate,
                &runtime,
                &HardwareButtonRequest::Other { description: "unlocking the device".to_string() },
            )
            .map(|features| ConnectedFeatures {
                device_id: features.device_id.clone(),
                label: features.label.clone(),
                model_name: features.model.clone(),
                firmware_version: firmware_version_string(&features),
            });

            let setup_ok = setup_result.is_ok();
            hw_log!("worker: handshake ok: {setup_ok}");
            let _ = setup_tx.send(setup_result);
            if !setup_ok {
                connected_for_thread.store(false, Ordering::SeqCst);
                return;
            }

            for command in command_rx {
                if matches!(command, Command::Disconnect) {
                    break;
                }

                let name = command.name();
                hw_log!("worker: {name} started");
                let outcome = catch_unwind(AssertUnwindSafe(|| handle(command, &mut trezor, &delegate, &runtime)));
                if let Err(payload) = outcome {
                    let reason = format!("{name} panicked: {}", panic_message(payload.as_ref()));
                    hw_log!("worker: {reason}");
                    if let Ok(mut failure) = failure_for_thread.lock() {
                        *failure = Some(reason);
                    }
                    break;
                }
            }

            connected_for_thread.store(false, Ordering::SeqCst);
            hw_log!("worker: stopped");
            runtime.block_on(delegate.did_disconnect());
        });

        (DeviceWorker { command_tx, connected, failure }, setup_rx)
    }

    pub(super) fn is_connected(&self) -> bool {
        self.connected.load(Ordering::SeqCst)
    }

    /// The error for a command whose reply never came: the worker thread
    /// panicked (reported as a failure, not a disconnect) or is gone.
    fn worker_lost(&self) -> HardwareError {
        let reason = self.failure.lock().ok().and_then(|failure| failure.clone());
        hw_log!("worker: command lost, panic: {reason:?}");
        match reason {
            Some(reason) => HardwareError::SigningFailed { reason },
            None => HardwareError::Disconnected,
        }
    }

    pub(super) async fn public_key(&self, path: Vec<HardwarePathSegment>) -> Result<Vec<u8>, HardwareError> {
        let (reply_tx, reply_rx) = oneshot::channel();
        self.command_tx
            .send(Command::PublicKey { path, reply: reply_tx })
            .map_err(|_| self.worker_lost())?;
        reply_rx.await.map_err(|_| self.worker_lost())?
    }

    pub(super) async fn ethereum_sign_tx(
        &self,
        path: Vec<HardwarePathSegment>,
        fields: EthereumTxFields,
    ) -> Result<EthereumSignature, HardwareError> {
        let (reply_tx, reply_rx) = oneshot::channel();
        self.command_tx
            .send(Command::EthereumSignTx { path, fields, reply: reply_tx })
            .map_err(|_| self.worker_lost())?;
        reply_rx.await.map_err(|_| self.worker_lost())?
    }

    pub(super) async fn ethereum_sign_tx_eip1559(
        &self,
        path: Vec<HardwarePathSegment>,
        fields: EthereumEIP1559TxFields,
    ) -> Result<EthereumEIP1559Signature, HardwareError> {
        let (reply_tx, reply_rx) = oneshot::channel::<Result<EthereumEIP1559Signature, HardwareError>>();
        self.command_tx
            .send(Command::EthereumSignTxEip1559 { path, fields, reply: reply_tx })
            .map_err(|_| self.worker_lost())?;
        reply_rx.await.map_err(|_| self.worker_lost())?
    }

    pub(super) async fn ethereum_sign_message(
        &self,
        path: Vec<HardwarePathSegment>,
        message: Vec<u8>,
    ) -> Result<EthereumSignature, HardwareError> {
        let (reply_tx, reply_rx) = oneshot::channel();
        self.command_tx
            .send(Command::EthereumSignMessage { path, message, reply: reply_tx })
            .map_err(|_| self.worker_lost())?;
        reply_rx.await.map_err(|_| self.worker_lost())?
    }

    pub(super) async fn ethereum_sign_typed_data(
        &self,
        path: Vec<HardwarePathSegment>,
        fields: EthereumTypedDataFields,
    ) -> Result<EthereumSignature, HardwareError> {
        let (reply_tx, reply_rx) = oneshot::channel();
        self.command_tx
            .send(Command::EthereumSignTypedData { path, fields, reply: reply_tx })
            .map_err(|_| self.worker_lost())?;
        reply_rx.await.map_err(|_| self.worker_lost())?
    }

    pub(super) async fn tron_sign_tx(
        &self,
        path: Vec<HardwarePathSegment>,
        fields: TronTxFields,
    ) -> Result<Vec<u8>, HardwareError> {
        let (reply_tx, reply_rx) = oneshot::channel();
        self.command_tx
            .send(Command::TronSignTx { path, fields, reply: reply_tx })
            .map_err(|_| self.worker_lost())?;
        reply_rx.await.map_err(|_| self.worker_lost())?
    }

    pub(super) async fn solana_public_key(&self, path: Vec<HardwarePathSegment>) -> Result<Vec<u8>, HardwareError> {
        let (reply_tx, reply_rx) = oneshot::channel();
        self.command_tx
            .send(Command::SolanaPublicKey { path, reply: reply_tx })
            .map_err(|_| self.worker_lost())?;
        reply_rx.await.map_err(|_| self.worker_lost())?
    }

    pub(super) async fn solana_sign_tx(
        &self,
        path: Vec<HardwarePathSegment>,
        fields: SolanaTxFields,
    ) -> Result<Vec<u8>, HardwareError> {
        let (reply_tx, reply_rx) = oneshot::channel();
        self.command_tx
            .send(Command::SolanaSignTx { path, fields, reply: reply_tx })
            .map_err(|_| self.worker_lost())?;
        reply_rx.await.map_err(|_| self.worker_lost())?
    }

    pub(super) async fn solana_sign_message(
        &self,
        path: Vec<HardwarePathSegment>,
        message: String,
        signers: Vec<Vec<u8>>,
    ) -> Result<Vec<u8>, HardwareError> {
        let (reply_tx, reply_rx) = oneshot::channel();
        self.command_tx
            .send(Command::SolanaSignMessage { path, message, signers, reply: reply_tx })
            .map_err(|_| self.worker_lost())?;
        reply_rx.await.map_err(|_| self.worker_lost())?
    }

    pub(super) async fn cardano_xpub(&self, path: Vec<HardwarePathSegment>) -> Result<String, HardwareError> {
        let (reply_tx, reply_rx) = oneshot::channel();
        self.command_tx.send(Command::CardanoXpub { path, reply: reply_tx }).map_err(|_| self.worker_lost())?;
        reply_rx.await.map_err(|_| self.worker_lost())?
    }

    pub(super) async fn cardano_sign_tx(&self, fields: CardanoTxFields) -> Result<Vec<CardanoWitness>, HardwareError> {
        let (reply_tx, reply_rx) = oneshot::channel();
        self.command_tx.send(Command::CardanoSignTx { fields, reply: reply_tx }).map_err(|_| self.worker_lost())?;
        reply_rx.await.map_err(|_| self.worker_lost())?
    }

    pub(super) async fn cardano_sign_dapp_tx(&self, request: CardanoDappTxRequest) -> Result<CardanoDappTxSignature, HardwareError> {
        let (reply_tx, reply_rx) = oneshot::channel();
        self.command_tx.send(Command::CardanoSignDappTx { request, reply: reply_tx }).map_err(|_| self.worker_lost())?;
        reply_rx.await.map_err(|_| self.worker_lost())?
    }

    pub(super) async fn cardano_sign_message(&self, request: CardanoMessageRequest) -> Result<CardanoMessageSignature, HardwareError> {
        let (reply_tx, reply_rx) = oneshot::channel();
        self.command_tx.send(Command::CardanoSignMessage { request, reply: reply_tx }).map_err(|_| self.worker_lost())?;
        reply_rx.await.map_err(|_| self.worker_lost())?
    }

    pub(super) async fn bitcoin_xpub(&self, path: Vec<HardwarePathSegment>) -> Result<String, HardwareError> {
        let (reply_tx, reply_rx) = oneshot::channel();
        self.command_tx
            .send(Command::BitcoinXpub { path, reply: reply_tx })
            .map_err(|_| self.worker_lost())?;
        reply_rx.await.map_err(|_| self.worker_lost())?
    }

    pub(super) async fn bitcoin_sign_psbt(
        &self,
        psbt: Vec<u8>,
        network: HardwareBitcoinNetwork,
    ) -> Result<Vec<u8>, HardwareError> {
        let (reply_tx, reply_rx) = oneshot::channel();
        self.command_tx
            .send(Command::BitcoinSignPsbt { psbt, network, reply: reply_tx })
            .map_err(|_| self.worker_lost())?;
        reply_rx.await.map_err(|_| self.worker_lost())?
    }

    pub(super) async fn disconnect(&self) {
        // Dropping the sender (implicitly, if this is the last handle)
        // would also end the loop, but sending `Disconnect` explicitly
        // lets the worker thread run `did_disconnect` deterministically
        // even while other clones of this handle are still alive.
        let _ = self.command_tx.send(Command::Disconnect);
    }
}

/// Runs one command to completion and sends its reply.
fn handle(
    command: Command,
    trezor: &mut Trezor,
    delegate: &Arc<dyn HardwareDeviceDelegate>,
    runtime: &tokio::runtime::Handle,
) {
    match command {
        Command::PublicKey { path, reply } => {
            let result = super::device::get_public_key(trezor, &path, delegate, runtime);
            reply_with(reply, result);
        }
        Command::EthereumSignTx { path, fields, reply } => {
            let result =
                super::device::ethereum_sign_tx(trezor, &path, fields, delegate, runtime);
            reply_with(reply, result);
        }
        Command::EthereumSignTxEip1559 { path, fields, reply } => {
            let result = super::device::ethereum_sign_tx_eip1559(
                trezor,
                &path,
                fields,
                delegate,
                runtime,
            );
            reply_with(reply, result);
        }
        Command::EthereumSignMessage { path, message, reply } => {
            let result =
                super::device::ethereum_sign_message(trezor, &path, message, delegate, runtime);
            reply_with(reply, result);
        }
        Command::EthereumSignTypedData { path, fields, reply } => {
            let result =
                super::device::ethereum_sign_typed_data(trezor, &path, fields, delegate, runtime);
            reply_with(reply, result);
        }
        Command::TronSignTx { path, fields, reply } => {
            let result = super::device::tron_sign_tx(trezor, &path, fields, delegate, runtime);
            reply_with(reply, result);
        }
        Command::SolanaPublicKey { path, reply } => {
            let result = super::device::solana_get_public_key(trezor, &path, delegate, runtime);
            reply_with(reply, result);
        }
        Command::SolanaSignTx { path, fields, reply } => {
            let result = super::device::solana_sign_tx(trezor, &path, fields, delegate, runtime);
            reply_with(reply, result);
        }
        Command::SolanaSignMessage { path, message, signers, reply } => {
            let result = super::device::solana_sign_message(
                trezor,
                &path,
                message,
                signers,
                delegate,
                runtime,
            );
            reply_with(reply, result);
        }
        Command::CardanoXpub { path, reply } => {
            let result = super::device::cardano_xpub(trezor, &path, delegate, runtime);
            reply_with(reply, result);
        }
        Command::CardanoSignTx { fields, reply } => {
            let result = super::device::cardano_sign_tx(trezor, fields, delegate, runtime);
            reply_with(reply, result);
        }
        Command::CardanoSignDappTx { request, reply } => {
            let result = super::device::cardano_sign_dapp_tx(trezor, request, delegate, runtime);
            reply_with(reply, result);
        }
        Command::CardanoSignMessage { request, reply } => {
            let result = super::device::cardano_sign_message(trezor, request, delegate, runtime);
            reply_with(reply, result);
        }
        Command::BitcoinXpub { path, reply } => {
            let result = super::device::bitcoin_xpub(trezor, &path, delegate, runtime);
            reply_with(reply, result);
        }
        Command::BitcoinSignPsbt { psbt, network, reply } => {
            let result =
                super::device::bitcoin_sign_psbt(trezor, &psbt, network, delegate, runtime);
            reply_with(reply, result);
        }
        Command::Disconnect => {}
    }
}

fn reply_with<T>(reply: oneshot::Sender<Result<T, HardwareError>>, result: Result<T, HardwareError>) {
    if let Err(error) = &result {
        hw_log!("worker: command failed: {error:?}");
    }
    let _ = reply.send(result);
}

fn panic_message(payload: &(dyn std::any::Any + Send)) -> String {
    payload
        .downcast_ref::<&str>()
        .map(|message| (*message).to_string())
        .or_else(|| payload.downcast_ref::<String>().cloned())
        .unwrap_or_else(|| "unknown panic".to_string())
}

/// Marks the worker disconnected however its thread exits, panics included.
struct ConnectedGuard(Arc<AtomicBool>);

impl Drop for ConnectedGuard {
    fn drop(&mut self) {
        self.0.store(false, Ordering::SeqCst);
    }
}

pub(super) fn firmware_version_string(features: &protos::Features) -> Option<String> {
    let (major, minor, patch) = (features.major_version?, features.minor_version?, features.patch_version?);
    Some(format!("{major}.{minor}.{patch}"))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn firmware_version_string_joins_the_three_version_components() {
        let mut features = protos::Features::new();
        features.set_major_version(2);
        features.set_minor_version(6);
        features.set_patch_version(3);
        assert_eq!(firmware_version_string(&features), Some("2.6.3".to_string()));
    }

    #[test]
    fn firmware_version_string_is_none_when_any_component_is_missing() {
        let mut features = protos::Features::new();
        features.set_major_version(2);
        assert_eq!(firmware_version_string(&features), None);
    }
}

/// Discards replies still queued on the device's WebUSB endpoint. A reply
/// nobody read (a handshake that failed mid-boot, an app quit mid-call)
/// stays queued across connections, after which every call reads the
/// previous call's reply. `trezor-client` reads with no timeout, so this
/// drains with its own short-timeout reads first.
fn drain_stale_replies(available: &AvailableDevice) {
    // `trezor-client` keeps the bus/address private; its `Display` shows
    // them as "... (transport: WebUSB (bus:address)) ...".
    let description = available.to_string();
    let Some((bus, address)) = description
        .split_once("WebUSB (")
        .and_then(|(_, rest)| rest.split_once(')'))
        .and_then(|(location, _)| location.split_once(':'))
        .and_then(|(bus, address)| Some((bus.parse::<u8>().ok()?, address.parse::<u8>().ok()?)))
    else {
        return;
    };

    let Ok(devices) = rusb::devices() else {
        return;
    };
    let Some(device) = devices.iter().find(|device| device.bus_number() == bus && device.address() == address) else {
        return;
    };
    let Ok(handle) = device.open() else {
        return;
    };

    let (interface, endpoint) = if available.debug { (1, 2) } else { (0, 1) };
    if handle.claim_interface(interface).is_err() {
        return;
    }

    let mut chunk = [0u8; 64];
    while handle.read_interrupt(0x80 | endpoint, &mut chunk, std::time::Duration::from_millis(100)).is_ok() {}
    let _ = handle.release_interface(interface);
}
