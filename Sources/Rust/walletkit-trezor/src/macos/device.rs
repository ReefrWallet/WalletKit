use std::sync::Arc;

use async_trait::async_trait;
use protobuf::MessageField;
use trezor_client::{protos, Trezor};
use walletkit_hardware::{
    EthereumEIP1559Signature, EthereumEIP1559TxFields, EthereumSignature, EthereumTxFields,
    HardwareBitcoinNetwork, HardwareButtonRequest, HardwareCurve, HardwareDevice as HardwareDeviceTrait,
    HardwareDeviceDelegate, HardwareDeviceInfo, HardwareError, HardwarePathSegment, SolanaTxFields,
    TronTxFields,
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
        match curve {
            HardwareCurve::Secp256k1 => self.worker.public_key(path).await,
            HardwareCurve::Ed25519 => self.worker.solana_public_key(path).await,
        }
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

    async fn tron_sign_tx(
        &self,
        path: Vec<HardwarePathSegment>,
        fields: TronTxFields,
    ) -> Result<Vec<u8>, HardwareError> {
        self.worker.tron_sign_tx(path, fields).await
    }

    async fn solana_sign_tx(
        &self,
        path: Vec<HardwarePathSegment>,
        fields: SolanaTxFields,
    ) -> Result<Vec<u8>, HardwareError> {
        self.worker.solana_sign_tx(path, fields).await
    }

    async fn bitcoin_xpub(&self, path: Vec<HardwarePathSegment>) -> Result<String, HardwareError> {
        self.worker.bitcoin_xpub(path).await
    }

    async fn bitcoin_sign_psbt(
        &self,
        psbt: Vec<u8>,
        network: HardwareBitcoinNetwork,
    ) -> Result<Vec<u8>, HardwareError> {
        self.worker.bitcoin_sign_psbt(psbt, network).await
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

/// Drives Trezor's `TronSignTx` → contract → `TronSignature` exchange for
/// the two contract types WalletKit can build: native transfers and TRC-20
/// calls. The device displays these structured fields before signing.
pub(super) fn tron_sign_tx(
    trezor: &mut Trezor,
    path: &[HardwarePathSegment],
    fields: TronTxFields,
    delegate: &Arc<dyn HardwareDeviceDelegate>,
    runtime: &tokio::runtime::Handle,
) -> Result<Vec<u8>, HardwareError> {
    let TronTxFields { ref_block_bytes, ref_block_hash, expiration, timestamp, fee_limit, data, contract } = fields;
    let mut request = protos::TronSignTx::new();
    request.address_n = path.iter().map(HardwarePathSegment::to_address_n).collect();
    request.set_ref_block_bytes(ref_block_bytes);
    request.set_ref_block_hash(ref_block_hash);
    request.set_expiration(expiration);
    request.set_timestamp(timestamp);
    if let Some(fee_limit) = fee_limit {
        request.set_fee_limit(fee_limit);
    }
    if let Some(data) = data {
        request.set_data(data);
    }

    let contract_request = drive_interaction(
        trezor.call(request, Box::new(|_, message: protos::TronContractRequest| Ok(message))),
        delegate,
        runtime,
        &HardwareButtonRequest::ConfirmTransaction,
    )?;
    let _ = contract_request;

    let signature = match contract {
        walletkit_hardware::TronContract::Transfer { owner_address, to_address, amount } => {
            let mut contract = protos::TronTransferContract::new();
            contract.set_owner_address(owner_address);
            contract.set_to_address(to_address);
            contract.set_amount(amount);
            drive_interaction(
                trezor.call(contract, Box::new(|_, message: protos::TronSignature| Ok(message))),
                delegate,
                runtime,
                &HardwareButtonRequest::ConfirmTransaction,
            )?
        }
        walletkit_hardware::TronContract::TriggerSmartContract { owner_address, contract_address, data } => {
            let mut contract = protos::TronTriggerSmartContract::new();
            contract.set_owner_address(owner_address);
            contract.set_contract_address(contract_address);
            contract.set_data(data);
            drive_interaction(
                trezor.call(contract, Box::new(|_, message: protos::TronSignature| Ok(message))),
                delegate,
                runtime,
                &HardwareButtonRequest::ConfirmTransaction,
            )?
        }
    };

    if !signature.has_signature() {
        return Err(HardwareError::SigningFailed { reason: "Trezor returned an empty Tron signature".to_string() });
    }
    Ok(signature.signature().to_vec())
}

/// Runs on the device's worker thread. Reads the ed25519 public key at
/// `path` via `SolanaGetPublicKey`/`SolanaPublicKey` — Trezor has no
/// generic ed25519 equivalent of the secp256k1-only `GetPublicKey`
/// message `get_public_key` above uses, so this is Solana-specific even
/// though the raw key material it returns isn't.
pub(super) fn solana_get_public_key(
    trezor: &mut Trezor,
    path: &[HardwarePathSegment],
    delegate: &Arc<dyn HardwareDeviceDelegate>,
    runtime: &tokio::runtime::Handle,
) -> Result<Vec<u8>, HardwareError> {
    let mut req = protos::SolanaGetPublicKey::new();
    req.address_n = path.iter().map(HardwarePathSegment::to_address_n).collect();
    req.set_show_display(false);

    let resp = drive_interaction(
        trezor.call(req, Box::new(|_, m: protos::SolanaPublicKey| Ok(m))),
        delegate,
        runtime,
        &HardwareButtonRequest::ConfirmPublicKey,
    )?;

    if !resp.has_public_key() {
        return Err(HardwareError::SigningFailed {
            reason: "Trezor returned an empty Solana public key".to_string(),
        });
    }
    Ok(resp.public_key().to_vec())
}

/// Runs on the device's worker thread. Sends `SolanaSignTx` with the
/// already-serialized wire-format message plus the token-account
/// metadata the trusted screen needs to show mint/owner instead of the
/// opaque token-account address, and returns the raw ed25519 signature.
/// Unlike the Ethereum/Tron flows, Solana has no streaming chunk protocol
/// — the whole message goes in one request and one `SolanaTxSignature`
/// comes back.
pub(super) fn solana_sign_tx(
    trezor: &mut Trezor,
    path: &[HardwarePathSegment],
    fields: SolanaTxFields,
    delegate: &Arc<dyn HardwareDeviceDelegate>,
    runtime: &tokio::runtime::Handle,
) -> Result<Vec<u8>, HardwareError> {
    let SolanaTxFields { serialized_message, token_accounts } = fields;

    let mut additional_info = protos::SolanaTxAdditionalInfo::new();
    additional_info.token_accounts_infos = token_accounts
        .into_iter()
        .map(|account| {
            let mut info = protos::SolanaTxTokenAccountInfo::new();
            info.set_base_address(account.base_address);
            info.set_token_program(account.token_program);
            info.set_token_mint(account.token_mint);
            info.set_token_account(account.token_account);
            info
        })
        .collect();

    let mut req = protos::SolanaSignTx::new();
    req.address_n = path.iter().map(HardwarePathSegment::to_address_n).collect();
    req.set_serialized_tx(serialized_message);
    req.additional_info = MessageField::some(additional_info);

    let resp = drive_interaction(
        trezor.call(req, Box::new(|_, m: protos::SolanaTxSignature| Ok(m))),
        delegate,
        runtime,
        &HardwareButtonRequest::ConfirmTransaction,
    )?;

    if !resp.has_signature() {
        return Err(HardwareError::SigningFailed { reason: "Trezor returned an empty Solana signature".to_string() });
    }
    Ok(resp.signature().to_vec())
}

/// Runs on the device's worker thread. Drives `trezor-client`'s own
/// `SignTx`/`TxRequest`/`TxAck` state machine (`Trezor::sign_tx` +
/// `SignTxProgress::ack_psbt`), which answers every request straight from
/// `psbt`'s `witness_utxo`/`bip32_derivation`/`tap_key_origins` fields —
/// the same ones `bitcoin_build_unsigned_psbt` already populates, so
/// nothing Bitcoin-specific needs hand-rolling the way the Ethereum flow
/// above does (that one exists to get PIN-hook interaction driving, which
/// this gets for free through the same `drive_interaction` calls).
///
/// The device streams the fully signed transaction back progressively as
/// `TxRequest.serialized.serialized_tx` chunks (concatenated here into
/// `raw_tx`) rather than per-input signatures — once
/// `SignTxProgress::finished()` is true, `raw_tx` is the complete,
/// consensus-serialized, broadcastable transaction.
pub(super) fn bitcoin_sign_psbt(
    trezor: &mut Trezor,
    psbt_bytes: &[u8],
    network: HardwareBitcoinNetwork,
    delegate: &Arc<dyn HardwareDeviceDelegate>,
    runtime: &tokio::runtime::Handle,
) -> Result<Vec<u8>, HardwareError> {
    let psbt = bitcoin::psbt::Psbt::deserialize(psbt_bytes)
        .map_err(|err| HardwareError::SigningFailed { reason: err.to_string() })?;
    let network = to_bitcoin_network(network);

    let mut progress = drive_interaction(
        trezor.sign_tx(&psbt, network),
        delegate,
        runtime,
        &HardwareButtonRequest::ConfirmTransaction,
    )?;

    let mut raw_tx = Vec::new();
    loop {
        if let Some(part) = progress.get_serialized_tx_part() {
            raw_tx.extend_from_slice(part);
        }
        if progress.finished() {
            break;
        }
        progress = drive_interaction(
            progress.ack_psbt(&psbt, network),
            delegate,
            runtime,
            &HardwareButtonRequest::ConfirmTransaction,
        )?;
    }

    Ok(raw_tx)
}

/// Runs on the device's worker thread. Reads the extended public key
/// (xpub, with its chain code intact) at `path` via the same
/// `GetPublicKey` wire message `get_public_key` uses — the difference is
/// this keeps the whole `bip32::Xpub` response (`.to_string()`) instead of
/// discarding its chain code down to the raw key, since a Bitcoin
/// descriptor needs to derive child addresses from it later without
/// going back to the device.
///
/// Always requests mainnet (`bitcoin::Network::Bitcoin`) serialization,
/// regardless of which Bitcoin network `path` is actually for — same as
/// `get_public_key` below, and for the same reason: `walletkit-ffi`'s
/// `ExtendedKeyFfi::from_serialized` only recognizes `xpub`/`xprv`
/// version bytes.
pub(super) fn bitcoin_xpub(
    trezor: &mut Trezor,
    path: &[HardwarePathSegment],
    delegate: &Arc<dyn HardwareDeviceDelegate>,
    runtime: &tokio::runtime::Handle,
) -> Result<String, HardwareError> {
    let derivation_path = to_bip32_path(path);
    let xpub = drive_interaction(
        trezor.get_public_key(&derivation_path, bitcoin::Network::Bitcoin, false),
        delegate,
        runtime,
        &HardwareButtonRequest::ConfirmPublicKey,
    )?;
    Ok(xpub.to_string())
}

fn to_bitcoin_network(network: HardwareBitcoinNetwork) -> bitcoin::Network {
    match network {
        HardwareBitcoinNetwork::Mainnet => bitcoin::Network::Bitcoin,
        HardwareBitcoinNetwork::Testnet => bitcoin::Network::Testnet,
        HardwareBitcoinNetwork::Signet => bitcoin::Network::Signet,
        HardwareBitcoinNetwork::Regtest => bitcoin::Network::Regtest,
    }
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
    fn to_bitcoin_network_maps_every_case() {
        assert_eq!(to_bitcoin_network(HardwareBitcoinNetwork::Mainnet), bitcoin::Network::Bitcoin);
        assert_eq!(to_bitcoin_network(HardwareBitcoinNetwork::Testnet), bitcoin::Network::Testnet);
        assert_eq!(to_bitcoin_network(HardwareBitcoinNetwork::Signet), bitcoin::Network::Signet);
        assert_eq!(to_bitcoin_network(HardwareBitcoinNetwork::Regtest), bitcoin::Network::Regtest);
    }

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
