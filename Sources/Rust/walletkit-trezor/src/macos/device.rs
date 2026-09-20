use std::sync::Arc;

use async_trait::async_trait;
use trezor_client::{protos, Trezor};
use walletkit_hardware::{
    EthereumEIP1559Signature, EthereumEIP1559TxFields, EthereumSignature, EthereumTxFields,
    HardwareButtonRequest, HardwareCurve, HardwareDevice as HardwareDeviceTrait, HardwareDeviceDelegate,
    HardwareDeviceInfo, HardwareError, HardwarePathSegment,
};

use super::{interaction::drive_interaction, worker::DeviceWorker};

/// A connected Trezor device. Every operation is served by a dedicated
/// worker thread (`DeviceWorker`) that owns the underlying `Trezor` client
/// for the device's whole connected lifetime — see that type's doc
/// comment for why.
pub struct TrezorDevice {
    info: std::sync::Mutex<HardwareDeviceInfo>,
    worker: DeviceWorker,
}

impl TrezorDevice {
    /// Connects to `available`, running the device's `Initialize`
    /// handshake before returning, and refining `info` (built from the
    /// scan-time `AvailableDevice`) with the real `device_id`/label/model/
    /// firmware version `Features` reports once connected.
    pub(super) async fn connect(
        available: trezor_client::AvailableDevice,
        info: HardwareDeviceInfo,
        delegate: Arc<dyn HardwareDeviceDelegate>,
    ) -> Result<Arc<dyn HardwareDeviceTrait>, HardwareError> {
        let (worker, setup_rx) = DeviceWorker::spawn(available, delegate, super::runtime::handle());
        let features = setup_rx.await.map_err(|_| HardwareError::Disconnected)??;

        let mut info = info;
        if let Some(device_id) = features.device_id {
            info.id = device_id;
        }
        info.label = features.label;
        if let Some(model_name) = features.model_name {
            info.model = model_name;
        }
        info.firmware_version = features.firmware_version;

        Ok(Arc::new(TrezorDevice { info: std::sync::Mutex::new(info), worker }))
    }
}

#[async_trait]
impl HardwareDeviceTrait for TrezorDevice {
    fn info(&self) -> HardwareDeviceInfo {
        self.info.lock().expect("info mutex poisoned").clone()
    }

    fn is_connected(&self) -> bool {
        self.worker.is_connected()
    }

    async fn public_key(
        &self,
        path: Vec<HardwarePathSegment>,
        curve: HardwareCurve,
    ) -> Result<Vec<u8>, HardwareError> {
        if curve != HardwareCurve::Secp256k1 {
            return Err(HardwareError::UnsupportedDevice {
                reason: "Trezor does not support retrieving ed25519 public keys yet".to_string(),
            });
        }
        self.worker.public_key(path).await
    }

    async fn ethereum_sign_tx(
        &self,
        path: Vec<HardwarePathSegment>,
        fields: EthereumTxFields,
    ) -> Result<EthereumSignature, HardwareError> {
        self.worker.ethereum_sign_tx(path, fields).await
    }

    async fn ethereum_sign_tx_eip1559(
        &self,
        path: Vec<HardwarePathSegment>,
        fields: EthereumEIP1559TxFields,
    ) -> Result<EthereumEIP1559Signature, HardwareError> {
        self.worker.ethereum_sign_tx_eip1559(path, fields).await
    }

    async fn disconnect(&self) {
        self.worker.disconnect().await
    }
}

/// Runs on the device's worker thread. Reads the secp256k1 public key at
/// `path` via the generic (chain-agnostic) `GetPublicKey` wire message —
/// Trezor has no Ethereum-specific equivalent; the same device instruction
/// backs every ECDSA chain, with `network`/`script_type` only affecting
/// how the response is xpub-serialized, not which key is derived.
pub(super) fn get_public_key(
    trezor: &mut Trezor,
    path: &[HardwarePathSegment],
    delegate: &Arc<dyn HardwareDeviceDelegate>,
    runtime: &tokio::runtime::Handle,
) -> Result<Vec<u8>, HardwareError> {
    let derivation_path = to_bip32_path(path);
    let xpub = drive_interaction(
        trezor.get_public_key(&derivation_path, bitcoin::Network::Bitcoin, false),
        delegate,
        runtime,
        &HardwareButtonRequest::ConfirmPublicKey,
    )?;
    Ok(xpub.public_key.serialize().to_vec())
}

/// Runs on the device's worker thread. Hand-rolls the `EthereumSignTx`
/// exchange (rather than using `Trezor::ethereum_sign_tx`) so
/// `drive_interaction` — not `trezor-client`'s own interaction handling,
/// which has no PIN hook — drives it. Mirrors `trezor-client`'s
/// `client::ethereum::Trezor::ethereum_sign_tx` field-for-field.
pub(super) fn ethereum_sign_tx(
    trezor: &mut Trezor,
    path: &[HardwarePathSegment],
    fields: EthereumTxFields,
    delegate: &Arc<dyn HardwareDeviceDelegate>,
    runtime: &tokio::runtime::Handle,
) -> Result<EthereumSignature, HardwareError> {
    let EthereumTxFields { nonce, gas_price, gas_limit, to, value, mut data, chain_id } = fields;

    let mut req = protos::EthereumSignTx::new();
    req.address_n = path.iter().map(HardwarePathSegment::to_address_n).collect();
    req.set_nonce(nonce);
    req.set_gas_price(gas_price);
    req.set_gas_limit(gas_limit);
    req.set_value(value);
    req.set_chain_id(chain_id);
    req.set_to(to_field(&to));

    req.set_data_length(data.len() as u32);
    req.set_data_initial_chunk(data.splice(..std::cmp::min(1024, data.len()), []).collect());

    let mut resp = drive_interaction(
        trezor.call(req, Box::new(|_, m: protos::EthereumTxRequest| Ok(m))),
        delegate,
        runtime,
        &HardwareButtonRequest::ConfirmTransaction,
    )?;

    while resp.data_length() > 0 {
        let mut ack = protos::EthereumTxAck::new();
        ack.set_data_chunk(data.splice(..std::cmp::min(1024, data.len()), []).collect());
        resp = drive_interaction(
            trezor.call(ack, Box::new(|_, m: protos::EthereumTxRequest| Ok(m))),
            delegate,
            runtime,
            &HardwareButtonRequest::ConfirmTransaction,
        )?;
    }

    // The device returns `v` in "Electrum" notation (0/1) when it computed
    // an EIP-155 signature for a known chain id; fold that into the full
    // EIP-155 value `EthereumSignerFfi::encode_signed` requires. If the
    // device already returned a full value (unlikely, since `chain_id` is
    // always set above), leave it untouched.
    let mut v = resp.signature_v() as u64;
    if v <= 1 {
        v = v + 2 * chain_id + 35;
    }
    Ok(EthereumSignature {
        v,
        r: resp.signature_r().to_vec(),
        s: resp.signature_s().to_vec(),
    })
}

/// Runs on the device's worker thread. Sends an `EthereumSignTxEIP1559` message
/// and drives the same `EthereumTxRequest`/`EthereumTxAck` chunk-streaming loop
/// as the legacy path. The device returns `signature_v` as `yParity` (0 or 1)
/// for type-2 — taken directly, no EIP-155 folding.
pub(super) fn ethereum_sign_tx_eip1559(
    trezor: &mut Trezor,
    path: &[HardwarePathSegment],
    fields: EthereumEIP1559TxFields,
    delegate: &Arc<dyn HardwareDeviceDelegate>,
    runtime: &tokio::runtime::Handle,
) -> Result<EthereumEIP1559Signature, HardwareError> {
    let EthereumEIP1559TxFields {
        nonce,
        max_priority_fee_per_gas,
        max_fee_per_gas,
        gas_limit,
        to,
        value,
        mut data,
        chain_id,
    } = fields;

    let mut req = protos::EthereumSignTxEIP1559::new();
    req.address_n = path.iter().map(HardwarePathSegment::to_address_n).collect();
    req.set_nonce(nonce);
    req.set_max_priority_fee(max_priority_fee_per_gas);
    req.set_max_gas_fee(max_fee_per_gas);
    req.set_gas_limit(gas_limit);
    req.set_value(value);
    req.set_chain_id(chain_id);
    req.set_to(to_field(&to));
    // access_list left empty — wallet transfers never set one

    req.set_data_length(data.len() as u32);
    req.set_data_initial_chunk(data.splice(..std::cmp::min(1024, data.len()), []).collect());

    let mut resp = drive_interaction(
        trezor.call(req, Box::new(|_, m: protos::EthereumTxRequest| Ok(m))),
        delegate,
        runtime,
        &HardwareButtonRequest::ConfirmTransaction,
    )?;

    while resp.data_length() > 0 {
        let mut ack = protos::EthereumTxAck::new();
        ack.set_data_chunk(data.splice(..std::cmp::min(1024, data.len()), []).collect());
        resp = drive_interaction(
            trezor.call(ack, Box::new(|_, m: protos::EthereumTxRequest| Ok(m))),
            delegate,
            runtime,
            &HardwareButtonRequest::ConfirmTransaction,
        )?;
    }

    // For EIP-1559 the device returns y_parity (0 or 1) directly — no folding.
    Ok(EthereumEIP1559Signature {
        y_parity: resp.signature_v() as u64,
        r: resp.signature_r().to_vec(),
        s: resp.signature_s().to_vec(),
    })
}

fn to_bip32_path(path: &[HardwarePathSegment]) -> bitcoin::bip32::DerivationPath {
    path.iter()
        .map(|segment| bitcoin::bip32::ChildNumber::from(segment.to_address_n()))
        .collect::<Vec<_>>()
        .into()
}

fn to_field(to: &Option<Vec<u8>>) -> String {
    match to {
        Some(bytes) => format!("0x{}", hex::encode(bytes)),
        None => String::new(),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn to_field_formats_a_recipient_as_a_hex_address() {
        assert_eq!(to_field(&Some(vec![0xab; 20])), format!("0x{}", "ab".repeat(20)));
    }

    #[test]
    fn to_field_is_empty_for_contract_creation() {
        assert_eq!(to_field(&None), "");
    }

    #[test]
    fn to_bip32_path_round_trips_through_address_n() {
        let path = [
            HardwarePathSegment { index: 44, hardened: true },
            HardwarePathSegment { index: 60, hardened: true },
            HardwarePathSegment { index: 0, hardened: true },
            HardwarePathSegment { index: 0, hardened: false },
            HardwarePathSegment { index: 0, hardened: false },
        ];
        let address_n: Vec<u32> = to_bip32_path(&path).into_iter().map(|child| u32::from(*child)).collect();
        assert_eq!(address_n, path.iter().map(HardwarePathSegment::to_address_n).collect::<Vec<_>>());
    }
}
