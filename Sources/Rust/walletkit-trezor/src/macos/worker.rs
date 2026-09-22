use std::sync::{
    atomic::{AtomicBool, Ordering},
    mpsc, Arc,
};

use tokio::sync::oneshot;
use trezor_client::{protos, AvailableDevice};
use walletkit_hardware::{
    EthereumEIP1559Signature, EthereumEIP1559TxFields, EthereumSignature, EthereumTxFields,
    HardwareBitcoinNetwork, HardwareButtonRequest, HardwareDeviceDelegate, HardwareError, HardwarePathSegment,
    SolanaTxFields, TronTxFields,
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

        std::thread::spawn(move || {
            let mut trezor = match available.connect().map_err(map_trezor_error) {
                Ok(trezor) => trezor,
                Err(err) => {
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
            let _ = setup_tx.send(setup_result);
            if !setup_ok {
                connected_for_thread.store(false, Ordering::SeqCst);
                return;
            }

            for command in command_rx {
                match command {
                    Command::PublicKey { path, reply } => {
                        let result = super::device::get_public_key(&mut trezor, &path, &delegate, &runtime);
                        let _ = reply.send(result);
                    }
                    Command::EthereumSignTx { path, fields, reply } => {
                        let result =
                            super::device::ethereum_sign_tx(&mut trezor, &path, fields, &delegate, &runtime);
                        let _ = reply.send(result);
                    }
                    Command::EthereumSignTxEip1559 { path, fields, reply } => {
                        let result = super::device::ethereum_sign_tx_eip1559(
                            &mut trezor,
                            &path,
                            fields,
                            &delegate,
                            &runtime,
                        );
                        let _ = reply.send(result);
                    }
                    Command::TronSignTx { path, fields, reply } => {
                        let result = super::device::tron_sign_tx(&mut trezor, &path, fields, &delegate, &runtime);
                        let _ = reply.send(result);
                    }
                    Command::SolanaPublicKey { path, reply } => {
                        let result = super::device::solana_get_public_key(&mut trezor, &path, &delegate, &runtime);
                        let _ = reply.send(result);
                    }
                    Command::SolanaSignTx { path, fields, reply } => {
                        let result = super::device::solana_sign_tx(&mut trezor, &path, fields, &delegate, &runtime);
                        let _ = reply.send(result);
                    }
                    Command::BitcoinXpub { path, reply } => {
                        let result = super::device::bitcoin_xpub(&mut trezor, &path, &delegate, &runtime);
                        let _ = reply.send(result);
                    }
                    Command::BitcoinSignPsbt { psbt, network, reply } => {
                        let result =
                            super::device::bitcoin_sign_psbt(&mut trezor, &psbt, network, &delegate, &runtime);
                        let _ = reply.send(result);
                    }
                    Command::Disconnect => break,
                }
            }

            connected_for_thread.store(false, Ordering::SeqCst);
            runtime.block_on(delegate.did_disconnect());
        });

        (DeviceWorker { command_tx, connected }, setup_rx)
    }

    pub(super) fn is_connected(&self) -> bool {
        self.connected.load(Ordering::SeqCst)
    }

    pub(super) async fn public_key(&self, path: Vec<HardwarePathSegment>) -> Result<Vec<u8>, HardwareError> {
        let (reply_tx, reply_rx) = oneshot::channel();
        self.command_tx
            .send(Command::PublicKey { path, reply: reply_tx })
            .map_err(|_| HardwareError::Disconnected)?;
        reply_rx.await.map_err(|_| HardwareError::Disconnected)?
    }

    pub(super) async fn ethereum_sign_tx(
        &self,
        path: Vec<HardwarePathSegment>,
        fields: EthereumTxFields,
    ) -> Result<EthereumSignature, HardwareError> {
        let (reply_tx, reply_rx) = oneshot::channel();
        self.command_tx
            .send(Command::EthereumSignTx { path, fields, reply: reply_tx })
            .map_err(|_| HardwareError::Disconnected)?;
        reply_rx.await.map_err(|_| HardwareError::Disconnected)?
    }

    pub(super) async fn ethereum_sign_tx_eip1559(
        &self,
        path: Vec<HardwarePathSegment>,
        fields: EthereumEIP1559TxFields,
    ) -> Result<EthereumEIP1559Signature, HardwareError> {
        let (reply_tx, reply_rx) = oneshot::channel::<Result<EthereumEIP1559Signature, HardwareError>>();
        self.command_tx
            .send(Command::EthereumSignTxEip1559 { path, fields, reply: reply_tx })
            .map_err(|_| HardwareError::Disconnected)?;
        reply_rx.await.map_err(|_| HardwareError::Disconnected)?
    }

    pub(super) async fn tron_sign_tx(
        &self,
        path: Vec<HardwarePathSegment>,
        fields: TronTxFields,
    ) -> Result<Vec<u8>, HardwareError> {
        let (reply_tx, reply_rx) = oneshot::channel();
        self.command_tx
            .send(Command::TronSignTx { path, fields, reply: reply_tx })
            .map_err(|_| HardwareError::Disconnected)?;
        reply_rx.await.map_err(|_| HardwareError::Disconnected)?
    }

    pub(super) async fn solana_public_key(&self, path: Vec<HardwarePathSegment>) -> Result<Vec<u8>, HardwareError> {
        let (reply_tx, reply_rx) = oneshot::channel();
        self.command_tx
            .send(Command::SolanaPublicKey { path, reply: reply_tx })
            .map_err(|_| HardwareError::Disconnected)?;
        reply_rx.await.map_err(|_| HardwareError::Disconnected)?
    }

    pub(super) async fn solana_sign_tx(
        &self,
        path: Vec<HardwarePathSegment>,
        fields: SolanaTxFields,
    ) -> Result<Vec<u8>, HardwareError> {
        let (reply_tx, reply_rx) = oneshot::channel();
        self.command_tx
            .send(Command::SolanaSignTx { path, fields, reply: reply_tx })
            .map_err(|_| HardwareError::Disconnected)?;
        reply_rx.await.map_err(|_| HardwareError::Disconnected)?
    }

    pub(super) async fn bitcoin_xpub(&self, path: Vec<HardwarePathSegment>) -> Result<String, HardwareError> {
        let (reply_tx, reply_rx) = oneshot::channel();
        self.command_tx
            .send(Command::BitcoinXpub { path, reply: reply_tx })
            .map_err(|_| HardwareError::Disconnected)?;
        reply_rx.await.map_err(|_| HardwareError::Disconnected)?
    }

    pub(super) async fn bitcoin_sign_psbt(
        &self,
        psbt: Vec<u8>,
        network: HardwareBitcoinNetwork,
    ) -> Result<Vec<u8>, HardwareError> {
        let (reply_tx, reply_rx) = oneshot::channel();
        self.command_tx
            .send(Command::BitcoinSignPsbt { psbt, network, reply: reply_tx })
            .map_err(|_| HardwareError::Disconnected)?;
        reply_rx.await.map_err(|_| HardwareError::Disconnected)?
    }

    pub(super) async fn disconnect(&self) {
        // Dropping the sender (implicitly, if this is the last handle)
        // would also end the loop, but sending `Disconnect` explicitly
        // lets the worker thread run `did_disconnect` deterministically
        // even while other clones of this handle are still alive.
        let _ = self.command_tx.send(Command::Disconnect);
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
