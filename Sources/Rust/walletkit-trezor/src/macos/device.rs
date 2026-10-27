use std::sync::Arc;

use async_trait::async_trait;
use protobuf::MessageField;
use trezor_client::{protos, protos::MessageType, Trezor, TrezorMessage};
use walletkit_hardware::{
    CardanoCertificate, CardanoCertificateKind, CardanoCredential, CardanoDRep, CardanoDappOutput, CardanoDappTxRequest,
    CardanoDappTxSignature, CardanoDatum, CardanoMessageAddressType, CardanoMessageRequest, CardanoMessageSignature,
    CardanoRequiredSigner, CardanoSigningMode, CardanoTxFields, CardanoWitness, EthereumEIP1559Signature, EthereumEIP1559TxFields, EthereumSignature, EthereumTxFields,
    EthereumTypedDataFields, HardwareBitcoinNetwork, HardwareButtonRequest, HardwareCurve,
    HardwareDevice as HardwareDeviceTrait, HardwareDeviceDelegate, HardwareDeviceInfo, HardwareError, HardwareInputRequest,
    HardwarePathSegment, SolanaTxFields, TronTxFields,
};

use super::{
    error::{map_failure, map_trezor_error},
    interaction::drive_interaction,
    worker::DeviceWorker,
};

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

    async fn ethereum_sign_message(
        &self,
        path: Vec<HardwarePathSegment>,
        message: Vec<u8>,
    ) -> Result<EthereumSignature, HardwareError> {
        self.worker.ethereum_sign_message(path, message).await
    }

    async fn ethereum_sign_typed_data(
        &self,
        path: Vec<HardwarePathSegment>,
        fields: EthereumTypedDataFields,
    ) -> Result<EthereumSignature, HardwareError> {
        self.worker.ethereum_sign_typed_data(path, fields).await
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

    async fn solana_sign_message(
        &self,
        path: Vec<HardwarePathSegment>,
        message: String,
        signers: Vec<Vec<u8>>,
    ) -> Result<Vec<u8>, HardwareError> {
        self.worker.solana_sign_message(path, message, signers).await
    }

    async fn cardano_xpub(&self, path: Vec<HardwarePathSegment>) -> Result<String, HardwareError> {
        self.worker.cardano_xpub(path).await
    }

    async fn cardano_sign_tx(&self, fields: CardanoTxFields) -> Result<Vec<CardanoWitness>, HardwareError> {
        self.worker.cardano_sign_tx(fields).await
    }

    async fn cardano_sign_dapp_tx(&self, request: CardanoDappTxRequest) -> Result<CardanoDappTxSignature, HardwareError> {
        request.validate()?;
        self.worker.cardano_sign_dapp_tx(request).await
    }

    async fn cardano_sign_message(&self, request: CardanoMessageRequest) -> Result<CardanoMessageSignature, HardwareError> {
        request.validate()?;
        self.worker.cardano_sign_message(request).await
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

/// Reads Cardano's extended account key through the chain-specific request so
/// the device applies Icarus derivation instead of SLIP-0010 Ed25519.
pub(super) fn cardano_xpub(
    trezor: &mut Trezor,
    path: &[HardwarePathSegment],
    delegate: &Arc<dyn HardwareDeviceDelegate>,
    runtime: &tokio::runtime::Handle,
) -> Result<String, HardwareError> {
    let mut request = protos::CardanoGetPublicKey::new();
    request.address_n = path.iter().map(HardwarePathSegment::to_address_n).collect();
    request.set_derivation_type(protos::CardanoDerivationType::ICARUS);
    let response = drive_interaction(
        trezor.call(request, Box::new(|_, response: protos::CardanoPublicKey| Ok(response))),
        delegate,
        runtime,
        &HardwareButtonRequest::ConfirmPublicKey,
    )?;
    response.xpub.ok_or_else(|| HardwareError::SigningFailed { reason: "Trezor returned an empty Cardano xpub".to_string() })
}

pub(super) fn cardano_sign_tx(
    trezor: &mut Trezor,
    fields: CardanoTxFields,
    delegate: &Arc<dyn HardwareDeviceDelegate>,
    runtime: &tokio::runtime::Handle,
) -> Result<Vec<CardanoWitness>, HardwareError> {
    let mut init = protos::CardanoSignTxInit::new();
    init.set_signing_mode(protos::CardanoTxSigningMode::ORDINARY_TRANSACTION);
    init.set_inputs_count(fields.inputs.len() as u32);
    init.set_outputs_count(fields.outputs.len() as u32);
    init.set_fee(fields.fee);
    init.set_network_id(fields.network_id as u32);
    init.set_protocol_magic(fields.protocol_magic);
    init.set_certificates_count(0);
    init.set_withdrawals_count(0);
    init.set_has_auxiliary_data(false);
    init.set_witness_requests_count(fields.witness_paths.len() as u32);
    init.set_minting_asset_groups_count(0);
    init.set_collateral_inputs_count(0);
    init.set_required_signers_count(0);
    init.set_include_network_id(false);
    init.set_tag_cbor_sets(true);
    init.set_derivation_type(protos::CardanoDerivationType::ICARUS);
    if let Some(ttl) = fields.ttl { init.set_ttl(ttl); }
    drive_interaction(trezor.call(init, Box::new(|_, response: protos::CardanoTxItemAck| Ok(response))), delegate, runtime, &HardwareButtonRequest::ConfirmTransaction)?;
    for input in fields.inputs {
        let mut message = protos::CardanoTxInput::new();
        message.set_prev_hash(input.tx_hash);
        message.set_prev_index(input.output_index);
        drive_interaction(trezor.call(message, Box::new(|_, response: protos::CardanoTxItemAck| Ok(response))), delegate, runtime, &HardwareButtonRequest::ConfirmTransaction)?;
    }
    for output in fields.outputs {
        let mut asset_groups: Vec<(Vec<u8>, Vec<_>)> = Vec::new();
        for asset in output.assets {
            if let Some((_, tokens)) = asset_groups.iter_mut().find(|(policy_id, _)| *policy_id == asset.policy_id) {
                tokens.push(asset);
            } else {
                asset_groups.push((asset.policy_id.clone(), vec![asset]));
            }
        }
        let mut message = protos::CardanoTxOutput::new();
        message.set_address(output.address);
        message.set_amount(output.lovelace);
        message.set_asset_groups_count(asset_groups.len() as u32);
        drive_interaction(trezor.call(message, Box::new(|_, response: protos::CardanoTxItemAck| Ok(response))), delegate, runtime, &HardwareButtonRequest::ConfirmTransaction)?;
        for (policy_id, assets) in asset_groups {
            let mut group = protos::CardanoAssetGroup::new();
            group.set_policy_id(policy_id);
            group.set_tokens_count(assets.len() as u32);
            drive_interaction(trezor.call(group, Box::new(|_, response: protos::CardanoTxItemAck| Ok(response))), delegate, runtime, &HardwareButtonRequest::ConfirmTransaction)?;
            for asset in assets {
                let mut token = protos::CardanoToken::new();
                token.set_asset_name_bytes(asset.name);
                token.set_amount(asset.quantity);
                drive_interaction(trezor.call(token, Box::new(|_, response: protos::CardanoTxItemAck| Ok(response))), delegate, runtime, &HardwareButtonRequest::ConfirmTransaction)?;
            }
        }
    }
    let mut witnesses = Vec::with_capacity(fields.witness_paths.len());
    for path in fields.witness_paths {
        let mut request = protos::CardanoTxWitnessRequest::new();
        request.path = path.iter().map(HardwarePathSegment::to_address_n).collect();
        let response = drive_interaction(trezor.call(request, Box::new(|_, response: protos::CardanoTxWitnessResponse| Ok(response))), delegate, runtime, &HardwareButtonRequest::ConfirmTransaction)?;
        let public_key = response.pub_key.ok_or_else(|| HardwareError::SigningFailed { reason: "Trezor returned an empty Cardano witness public key".to_string() })?;
        let signature = response.signature.ok_or_else(|| HardwareError::SigningFailed { reason: "Trezor returned an empty Cardano witness signature".to_string() })?;
        witnesses.push(CardanoWitness { public_key, signature });
    }
    let body_hash = drive_interaction(trezor.call(protos::CardanoTxHostAck::new(), Box::new(|_, response: protos::CardanoTxBodyHash| Ok(response))), delegate, runtime, &HardwareButtonRequest::ConfirmTransaction)?;
    if body_hash.tx_hash != Some(fields.body_hash.clone()) {
        return Err(HardwareError::SigningFailed {
            reason: format!(
                "Trezor reconstructed a different Cardano transaction body (expected {}, got {})",
                hex::encode(fields.body_hash),
                body_hash.tx_hash.map(hex::encode).unwrap_or_else(|| "none".to_string())
            ),
        });
    }
    drive_interaction(trezor.call(protos::CardanoTxHostAck::new(), Box::new(|_, response: protos::CardanoSignTxFinished| Ok(response))), delegate, runtime, &HardwareButtonRequest::ConfirmTransaction)?;
    Ok(witnesses)
}

/// One body item the device asks for, in the order the firmware consumes
/// them (`signer.py::_processs_tx_init`).
#[derive(Debug, Clone, PartialEq)]
pub(super) enum CardanoTxItem {
    AssetGroup(protos::CardanoAssetGroup),
    AuxiliaryData(protos::CardanoTxAuxiliaryData),
    CollateralInput(protos::CardanoTxCollateralInput),
    Certificate(protos::CardanoTxCertificate),
    InlineDatumChunk(protos::CardanoTxInlineDatumChunk),
    Input(protos::CardanoTxInput),
    Mint(protos::CardanoTxMint),
    Output(protos::CardanoTxOutput),
    ReferenceInput(protos::CardanoTxReferenceInput),
    ReferenceScriptChunk(protos::CardanoTxReferenceScriptChunk),
    RequiredSigner(protos::CardanoTxRequiredSigner),
    Token(protos::CardanoToken),
    Withdrawal(protos::CardanoTxWithdrawal),
}

/// Largest datum/script chunk the firmware accepts.
const CARDANO_CHUNK_SIZE: usize = 1024;

fn required(value: Option<Vec<u8>>, what: &str) -> Result<Vec<u8>, HardwareError> {
    value.ok_or_else(|| HardwareError::SigningFailed { reason: format!("Trezor returned an empty {what}") })
}

fn address_n(path: &[HardwarePathSegment]) -> Vec<u32> {
    path.iter().map(HardwarePathSegment::to_address_n).collect()
}

fn to_signing_mode(mode: CardanoSigningMode) -> protos::CardanoTxSigningMode {
    match mode {
        CardanoSigningMode::Multisig => protos::CardanoTxSigningMode::MULTISIG_TRANSACTION,
        CardanoSigningMode::Ordinary => protos::CardanoTxSigningMode::ORDINARY_TRANSACTION,
        CardanoSigningMode::Plutus => protos::CardanoTxSigningMode::PLUTUS_TRANSACTION,
    }
}

fn push_output(items: &mut Vec<CardanoTxItem>, output: &CardanoDappOutput) -> protos::CardanoTxOutput {
    let mut asset_groups: Vec<(&[u8], Vec<&walletkit_hardware::CardanoAsset>)> = Vec::new();
    for asset in &output.assets {
        match asset_groups.iter_mut().find(|(policy_id, _)| *policy_id == asset.policy_id.as_slice()) {
            Some((_, tokens)) => tokens.push(asset),
            None => asset_groups.push((&asset.policy_id, vec![asset])),
        }
    }
    let mut message = protos::CardanoTxOutput::new();
    message.set_address(output.address.clone());
    message.set_amount(output.lovelace);
    message.set_asset_groups_count(asset_groups.len() as u32);
    let inline_datum = match &output.datum {
        Some(CardanoDatum::Hash(hash)) => {
            message.set_datum_hash(hash.clone());
            None
        }
        Some(CardanoDatum::Inline(data)) => Some(data),
        None => None,
    };
    message.set_format(if output.post_alonzo {
        protos::CardanoTxOutputSerializationFormat::MAP_BABBAGE
    } else {
        protos::CardanoTxOutputSerializationFormat::ARRAY_LEGACY
    });
    message.set_inline_datum_size(inline_datum.map_or(0, |data| data.len() as u32));
    message.set_reference_script_size(output.reference_script.as_ref().map_or(0, |script| script.len() as u32));
    items.push(CardanoTxItem::Output(message.clone()));
    for (policy_id, tokens) in asset_groups {
        let mut group = protos::CardanoAssetGroup::new();
        group.set_policy_id(policy_id.to_vec());
        group.set_tokens_count(tokens.len() as u32);
        items.push(CardanoTxItem::AssetGroup(group));
        for asset in tokens {
            let mut token = protos::CardanoToken::new();
            token.set_asset_name_bytes(asset.name.clone());
            token.set_amount(asset.quantity);
            items.push(CardanoTxItem::Token(token));
        }
    }
    for chunk in inline_datum.into_iter().flat_map(|data| data.chunks(CARDANO_CHUNK_SIZE)) {
        let mut message = protos::CardanoTxInlineDatumChunk::new();
        message.set_data(chunk.to_vec());
        items.push(CardanoTxItem::InlineDatumChunk(message));
    }
    for chunk in output.reference_script.iter().flat_map(|script| script.chunks(CARDANO_CHUNK_SIZE)) {
        let mut message = protos::CardanoTxReferenceScriptChunk::new();
        message.set_data(chunk.to_vec());
        items.push(CardanoTxItem::ReferenceScriptChunk(message));
    }
    message
}

fn set_credential(credential: &CardanoCredential, path: &mut Vec<u32>, key_hash: &mut Option<Vec<u8>>, script_hash: &mut Option<Vec<u8>>) {
    match credential {
        CardanoCredential::KeyHash(hash) => *key_hash = Some(hash.clone()),
        CardanoCredential::Path(segments) => *path = address_n(segments),
        CardanoCredential::ScriptHash(hash) => *script_hash = Some(hash.clone()),
    }
}

fn to_certificate(certificate: &CardanoCertificate) -> Result<protos::CardanoTxCertificate, HardwareError> {
    use protos::CardanoCertificateType as Kind;
    let mut message = protos::CardanoTxCertificate::new();
    message.set_type(match &certificate.kind {
        CardanoCertificateKind::StakeDelegation => Kind::STAKE_DELEGATION,
        CardanoCertificateKind::StakeDeregistration => Kind::STAKE_DEREGISTRATION,
        CardanoCertificateKind::StakeDeregistrationConway => Kind::STAKE_DEREGISTRATION_CONWAY,
        CardanoCertificateKind::StakeRegistration => Kind::STAKE_REGISTRATION,
        CardanoCertificateKind::StakeRegistrationConway => Kind::STAKE_REGISTRATION_CONWAY,
        CardanoCertificateKind::VoteDelegation => Kind::VOTE_DELEGATION,
        CardanoCertificateKind::Unsupported { name } => {
            return Err(HardwareError::UnsupportedDevice { reason: format!("unsupported {name} certificate") })
        }
    });
    let (mut path, mut key_hash, mut script_hash) = (Vec::new(), None, None);
    set_credential(&certificate.credential, &mut path, &mut key_hash, &mut script_hash);
    message.path = path;
    message.key_hash = key_hash;
    message.script_hash = script_hash;
    message.pool = certificate.pool.clone();
    message.deposit = certificate.deposit;
    if let Some(drep) = &certificate.drep {
        let mut message_drep = protos::CardanoDRep::new();
        match drep {
            CardanoDRep::Abstain => message_drep.set_type(protos::CardanoDRepType::ABSTAIN),
            CardanoDRep::KeyHash(hash) => {
                message_drep.set_type(protos::CardanoDRepType::KEY_HASH);
                message_drep.set_key_hash(hash.clone());
            }
            CardanoDRep::NoConfidence => message_drep.set_type(protos::CardanoDRepType::NO_CONFIDENCE),
            CardanoDRep::ScriptHash(hash) => {
                message_drep.set_type(protos::CardanoDRepType::SCRIPT_HASH);
                message_drep.set_script_hash(hash.clone());
            }
        }
        message.drep = MessageField::some(message_drep);
    }
    Ok(message)
}

/// Maps a dApp request to the init message and the ordered item stream.
/// Pure: nothing is sent, so it also validates the request.
pub(super) fn plan_dapp_tx(request: &CardanoDappTxRequest) -> Result<(protos::CardanoSignTxInit, Vec<CardanoTxItem>), HardwareError> {
    let mode = request.validate()?;
    let mut items = Vec::new();

    for input in &request.inputs {
        let mut message = protos::CardanoTxInput::new();
        message.set_prev_hash(input.tx_hash.clone());
        message.set_prev_index(input.output_index);
        items.push(CardanoTxItem::Input(message));
    }
    for output in &request.outputs {
        push_output(&mut items, output);
    }
    for certificate in &request.certificates {
        items.push(CardanoTxItem::Certificate(to_certificate(certificate)?));
    }
    for withdrawal in &request.withdrawals {
        let mut message = protos::CardanoTxWithdrawal::new();
        message.set_amount(withdrawal.amount);
        let (mut path, mut key_hash, mut script_hash) = (Vec::new(), None, None);
        set_credential(&withdrawal.credential, &mut path, &mut key_hash, &mut script_hash);
        message.path = path;
        message.key_hash = key_hash;
        message.script_hash = script_hash;
        items.push(CardanoTxItem::Withdrawal(message));
    }
    if let Some(hash) = &request.auxiliary_data_hash {
        let mut message = protos::CardanoTxAuxiliaryData::new();
        message.set_hash(hash.clone());
        items.push(CardanoTxItem::AuxiliaryData(message));
    }
    if !request.mint.is_empty() {
        let mut mint = protos::CardanoTxMint::new();
        mint.set_asset_groups_count(request.mint.len() as u32);
        items.push(CardanoTxItem::Mint(mint));
        for group in &request.mint {
            let mut message = protos::CardanoAssetGroup::new();
            message.set_policy_id(group.policy_id.clone());
            message.set_tokens_count(group.tokens.len() as u32);
            items.push(CardanoTxItem::AssetGroup(message));
            for token in &group.tokens {
                let mut message = protos::CardanoToken::new();
                message.set_asset_name_bytes(token.name.clone());
                message.set_mint_amount(token.amount);
                items.push(CardanoTxItem::Token(message));
            }
        }
    }
    for input in &request.collateral_inputs {
        let mut message = protos::CardanoTxCollateralInput::new();
        message.set_prev_hash(input.tx_hash.clone());
        message.set_prev_index(input.output_index);
        items.push(CardanoTxItem::CollateralInput(message));
    }
    for signer in &request.required_signers {
        let mut message = protos::CardanoTxRequiredSigner::new();
        match signer {
            CardanoRequiredSigner::KeyHash(hash) => message.set_key_hash(hash.clone()),
            CardanoRequiredSigner::Path(path) => message.key_path = address_n(path),
        }
        items.push(CardanoTxItem::RequiredSigner(message));
    }
    if let Some(output) = &request.collateral_return {
        push_output(&mut items, output);
    }
    for input in &request.reference_inputs {
        let mut message = protos::CardanoTxReferenceInput::new();
        message.set_prev_hash(input.tx_hash.clone());
        message.set_prev_index(input.output_index);
        items.push(CardanoTxItem::ReferenceInput(message));
    }

    let mut init = protos::CardanoSignTxInit::new();
    init.set_signing_mode(to_signing_mode(mode));
    init.set_protocol_magic(request.protocol_magic);
    init.set_network_id(u32::from(request.network_id));
    init.set_inputs_count(request.inputs.len() as u32);
    init.set_outputs_count(request.outputs.len() as u32);
    init.set_fee(request.fee);
    if let Some(ttl) = request.ttl {
        init.set_ttl(ttl);
    }
    init.set_certificates_count(request.certificates.len() as u32);
    init.set_withdrawals_count(request.withdrawals.len() as u32);
    init.set_has_auxiliary_data(request.auxiliary_data_hash.is_some());
    if let Some(start) = request.validity_start {
        init.set_validity_interval_start(start);
    }
    init.set_witness_requests_count(request.witness_paths.len() as u32);
    init.set_minting_asset_groups_count(request.mint.len() as u32);
    init.set_derivation_type(protos::CardanoDerivationType::ICARUS);
    init.set_include_network_id(request.include_network_id);
    if let Some(hash) = &request.script_data_hash {
        init.set_script_data_hash(hash.clone());
    }
    init.set_collateral_inputs_count(request.collateral_inputs.len() as u32);
    init.set_required_signers_count(request.required_signers.len() as u32);
    init.set_has_collateral_return(request.collateral_return.is_some());
    if let Some(total) = request.total_collateral {
        init.set_total_collateral(total);
    }
    init.set_reference_inputs_count(request.reference_inputs.len() as u32);
    init.set_tag_cbor_sets(request.tag_cbor_sets);
    Ok((init, items))
}

fn send_item<S: TrezorMessage>(
    trezor: &mut Trezor,
    message: S,
    delegate: &Arc<dyn HardwareDeviceDelegate>,
    runtime: &tokio::runtime::Handle,
) -> Result<(), HardwareError> {
    drive_interaction(trezor.call(message, Box::new(|_, response: protos::CardanoTxItemAck| Ok(response))), delegate, runtime, &HardwareButtonRequest::ConfirmTransaction)?;
    Ok(())
}

pub(super) fn cardano_sign_dapp_tx(
    trezor: &mut Trezor,
    request: CardanoDappTxRequest,
    delegate: &Arc<dyn HardwareDeviceDelegate>,
    runtime: &tokio::runtime::Handle,
) -> Result<CardanoDappTxSignature, HardwareError> {
    let (init, items) = plan_dapp_tx(&request)?;
    let button = HardwareButtonRequest::ConfirmTransaction;
    send_item(trezor, init, delegate, runtime)?;
    for item in items {
        match item {
            CardanoTxItem::AssetGroup(message) => send_item(trezor, message, delegate, runtime)?,
            CardanoTxItem::AuxiliaryData(message) => {
                // The device answers with its own supplement; acknowledge it.
                drive_interaction(trezor.call(message, Box::new(|_, response: protos::CardanoTxAuxiliaryDataSupplement| Ok(response))), delegate, runtime, &button)?;
                send_item(trezor, protos::CardanoTxHostAck::new(), delegate, runtime)?;
            }
            CardanoTxItem::CollateralInput(message) => send_item(trezor, message, delegate, runtime)?,
            CardanoTxItem::Certificate(message) => send_item(trezor, message, delegate, runtime)?,
            CardanoTxItem::InlineDatumChunk(message) => send_item(trezor, message, delegate, runtime)?,
            CardanoTxItem::Input(message) => send_item(trezor, message, delegate, runtime)?,
            CardanoTxItem::Mint(message) => send_item(trezor, message, delegate, runtime)?,
            CardanoTxItem::Output(message) => send_item(trezor, message, delegate, runtime)?,
            CardanoTxItem::ReferenceInput(message) => send_item(trezor, message, delegate, runtime)?,
            CardanoTxItem::ReferenceScriptChunk(message) => send_item(trezor, message, delegate, runtime)?,
            CardanoTxItem::RequiredSigner(message) => send_item(trezor, message, delegate, runtime)?,
            CardanoTxItem::Token(message) => send_item(trezor, message, delegate, runtime)?,
            CardanoTxItem::Withdrawal(message) => send_item(trezor, message, delegate, runtime)?,
        }
    }
    let mut witnesses = Vec::with_capacity(request.witness_paths.len());
    for path in &request.witness_paths {
        let mut message = protos::CardanoTxWitnessRequest::new();
        message.path = address_n(path);
        let response = drive_interaction(trezor.call(message, Box::new(|_, response: protos::CardanoTxWitnessResponse| Ok(response))), delegate, runtime, &button)?;
        witnesses.push(CardanoWitness {
            public_key: required(response.pub_key, "Cardano witness public key")?,
            signature: required(response.signature, "Cardano witness signature")?,
        });
    }
    let body_hash = drive_interaction(trezor.call(protos::CardanoTxHostAck::new(), Box::new(|_, response: protos::CardanoTxBodyHash| Ok(response))), delegate, runtime, &button)?;
    drive_interaction(trezor.call(protos::CardanoTxHostAck::new(), Box::new(|_, response: protos::CardanoSignTxFinished| Ok(response))), delegate, runtime, &button)?;
    Ok(CardanoDappTxSignature { body_hash: required(body_hash.tx_hash, "Cardano body hash")?, witnesses })
}

fn to_message_address(address: &walletkit_hardware::CardanoMessageAddress) -> protos::CardanoAddressParametersType {
    let mut parameters = protos::CardanoAddressParametersType::new();
    parameters.set_address_type(match address.address_type {
        CardanoMessageAddressType::Base => protos::CardanoAddressType::BASE,
        CardanoMessageAddressType::BaseKeyScript => protos::CardanoAddressType::BASE_KEY_SCRIPT,
        CardanoMessageAddressType::Enterprise => protos::CardanoAddressType::ENTERPRISE,
        CardanoMessageAddressType::Reward => protos::CardanoAddressType::REWARD,
    });
    parameters.address_n = address_n(&address.path);
    parameters.address_n_staking = address_n(&address.staking_path);
    parameters.staking_key_hash = address.staking_key_hash.clone();
    parameters
}

/// The init message of a CIP-8 signature; the payload is streamed later.
pub(super) fn plan_message(request: &CardanoMessageRequest) -> Result<protos::CardanoSignMessageInit, HardwareError> {
    request.validate()?;
    let mut init = protos::CardanoSignMessageInit::new();
    init.signing_path = address_n(&request.signing_path);
    init.set_payload_size(request.payload.len() as u32);
    init.set_prefer_hex_display(request.prefer_hex_display);
    init.set_derivation_type(protos::CardanoDerivationType::ICARUS);
    if let Some(address) = &request.address {
        init.set_protocol_magic(address.protocol_magic);
        init.set_network_id(u32::from(address.network_id));
        init.address_parameters = MessageField::some(to_message_address(address));
    }
    Ok(init)
}

/// Drives `CardanoSignMessageInit` with raw messages: the device answers
/// either with a payload request or, for an empty payload, with the
/// signature directly, which a typed `call` can't express.
pub(super) fn cardano_sign_message(
    trezor: &mut Trezor,
    request: CardanoMessageRequest,
    delegate: &Arc<dyn HardwareDeviceDelegate>,
    runtime: &tokio::runtime::Handle,
) -> Result<CardanoMessageSignature, HardwareError> {
    let init = plan_message(&request)?;
    let button = HardwareButtonRequest::Other { description: "Confirm Cardano message".to_string() };
    let mut message = trezor.call_raw(init).map_err(map_trezor_error)?;
    let mut pin_attempt = 0;
    loop {
        message = match message.message_type() {
            MessageType::MessageType_CardanoMessageSignature => {
                let signature: protos::CardanoMessageSignature = message.into_message().map_err(|error| map_trezor_error(error.into()))?;
                return Ok(CardanoMessageSignature {
                    address: required(signature.address, "Cardano message address")?,
                    pub_key: required(signature.pub_key, "Cardano message public key")?,
                    signature: required(signature.signature, "Cardano message signature")?,
                });
            }
            MessageType::MessageType_CardanoMessageDataRequest => {
                let data_request: protos::CardanoMessageDataRequest = message.into_message().map_err(|error| map_trezor_error(error.into()))?;
                let Some(chunk) = request.chunk(data_request.length(), data_request.offset()) else {
                    return Err(HardwareError::SigningFailed { reason: "Trezor requested data beyond the Cardano message payload".to_string() });
                };
                let mut response = protos::CardanoMessageDataResponse::new();
                response.set_data(chunk.to_vec());
                trezor.call_raw(response).map_err(map_trezor_error)?
            }
            MessageType::MessageType_ButtonRequest => {
                runtime.block_on(delegate.waiting_for_confirmation(button.clone()));
                trezor.call_raw(protos::ButtonAck::new()).map_err(map_trezor_error)?
            }
            MessageType::MessageType_PinMatrixRequest => {
                pin_attempt += 1;
                let pin = runtime.block_on(delegate.needs_input(HardwareInputRequest::Pin { attempt: pin_attempt }));
                let Some(pin) = pin else { return Err(HardwareError::UserCancelled) };
                let mut ack = protos::PinMatrixAck::new();
                ack.set_pin(pin);
                trezor.call_raw(ack).map_err(map_trezor_error)?
            }
            MessageType::MessageType_PassphraseRequest => {
                let passphrase = runtime.block_on(delegate.needs_input(HardwareInputRequest::Passphrase));
                let Some(passphrase) = passphrase else { return Err(HardwareError::UserCancelled) };
                let mut ack = protos::PassphraseAck::new();
                ack.set_passphrase(passphrase);
                trezor.call_raw(ack).map_err(map_trezor_error)?
            }
            MessageType::MessageType_Failure => {
                let failure: protos::Failure = message.into_message().map_err(|error| map_trezor_error(error.into()))?;
                return Err(super::error::map_failure(&failure));
            }
            other => return Err(map_trezor_error(trezor_client::Error::UnexpectedMessageType(other))),
        };
    }
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

fn signature_from_bytes(raw: &[u8]) -> Result<EthereumSignature, HardwareError> {
    if raw.len() != 65 {
        return Err(HardwareError::SigningFailed {
            reason: format!("expected a 65-byte signature, got {} bytes", raw.len()),
        });
    }
    Ok(EthereumSignature { v: raw[64] as u64, r: raw[0..32].to_vec(), s: raw[32..64].to_vec() })
}

/// Runs on the device's worker thread. Hand-rolls the `EthereumSignMessage`
/// exchange (rather than using `Trezor::ethereum_sign_message`) so
/// `drive_interaction` drives it, for the same PIN-hook reason
/// `ethereum_sign_tx` above does. Unlike `ethereum_sign_tx`, there's no
/// chunk-streaming loop — `EthereumSignMessage` carries the whole message
/// in one request and gets one `EthereumMessageSignature` back.
pub(super) fn ethereum_sign_message(
    trezor: &mut Trezor,
    path: &[HardwarePathSegment],
    message: Vec<u8>,
    delegate: &Arc<dyn HardwareDeviceDelegate>,
    runtime: &tokio::runtime::Handle,
) -> Result<EthereumSignature, HardwareError> {
    let mut req = protos::EthereumSignMessage::new();
    req.address_n = path.iter().map(HardwarePathSegment::to_address_n).collect();
    req.set_message(message);

    let resp = drive_interaction(
        trezor.call(req, Box::new(|_, m: protos::EthereumMessageSignature| Ok(m))),
        delegate,
        runtime,
        &HardwareButtonRequest::Other { description: "signing the message".to_string() },
    )?;
    signature_from_bytes(resp.signature())
}

/// Runs on the device's worker thread. Dispatches to Trezor One's
/// `EthereumSignTypedHash` fallback or the full interactive
/// `EthereumSignTypedData` struct/value walk, based on the connected
/// device's reported model — Trezor One's firmware doesn't implement the
/// full flow at all.
pub(super) fn ethereum_sign_typed_data(
    trezor: &mut Trezor,
    path: &[HardwarePathSegment],
    fields: EthereumTypedDataFields,
    delegate: &Arc<dyn HardwareDeviceDelegate>,
    runtime: &tokio::runtime::Handle,
) -> Result<EthereumSignature, HardwareError> {
    let is_trezor_one = trezor.features().and_then(|features| features.model.as_deref()) == Some("1");
    if is_trezor_one {
        ethereum_sign_typed_hash(trezor, path, &fields, delegate, runtime)
    } else {
        ethereum_sign_typed_data_full(trezor, path, fields, delegate, runtime)
    }
}

/// Trezor One's firmware doesn't implement the interactive
/// `EthereumSignTypedData` struct/value walk — it only signs the two
/// already-computed EIP-712 hashes directly via `EthereumSignTypedHash`.
fn ethereum_sign_typed_hash(
    trezor: &mut Trezor,
    path: &[HardwarePathSegment],
    fields: &EthereumTypedDataFields,
    delegate: &Arc<dyn HardwareDeviceDelegate>,
    runtime: &tokio::runtime::Handle,
) -> Result<EthereumSignature, HardwareError> {
    let mut req = protos::EthereumSignTypedHash::new();
    req.address_n = path.iter().map(HardwarePathSegment::to_address_n).collect();
    req.set_domain_separator_hash(fields.domain_separator_hash.clone());
    req.set_message_hash(fields.message_hash.clone());

    let resp = drive_interaction(
        trezor.call(req, Box::new(|_, m: protos::EthereumTypedDataSignature| Ok(m))),
        delegate,
        runtime,
        &HardwareButtonRequest::Other { description: "signing the typed data".to_string() },
    )?;
    signature_from_bytes(resp.signature())
}

/// Drives the full interactive `EthereumSignTypedData` exchange on Trezor
/// Model T/Safe — answering each `EthereumTypedDataStructRequest`/
/// `EthereumTypedDataValueRequest` from `fields`'s verbatim `types`/
/// `domain`/`message` JSON. Mirrors `trezorlib.ethereum.sign_typed_data`
/// (the Trezor team's own Python reference client) field-for-field, since
/// `trezor-client` has no Rust convenience wrapper for this message.
fn ethereum_sign_typed_data_full(
    trezor: &mut Trezor,
    path: &[HardwarePathSegment],
    fields: EthereumTypedDataFields,
    delegate: &Arc<dyn HardwareDeviceDelegate>,
    runtime: &tokio::runtime::Handle,
) -> Result<EthereumSignature, HardwareError> {
    let types = parse_json(&fields.types_json)?;
    let domain = parse_json(&fields.domain_json)?;
    let message = parse_json(&fields.message_json)?;

    let mut req = protos::EthereumSignTypedData::new();
    req.address_n = path.iter().map(HardwarePathSegment::to_address_n).collect();
    req.set_primary_type(fields.primary_type.clone());
    req.set_metamask_v4_compat(true);

    let mut step = call_typed_data_step(trezor, req, delegate, runtime)?;
    loop {
        step = match step {
            TypedDataStep::StructRequest(request) => {
                let mut ack = protos::EthereumTypedDataStructAck::new();
                ack.members = struct_members(&types, request.name())?;
                call_typed_data_step(trezor, ack, delegate, runtime)?
            }
            TypedDataStep::ValueRequest(request) => {
                let value =
                    encode_member_value(&fields.primary_type, &domain, &message, &request.member_path, &types)?;
                let mut ack = protos::EthereumTypedDataValueAck::new();
                ack.set_value(value);
                call_typed_data_step(trezor, ack, delegate, runtime)?
            }
            TypedDataStep::Signature(signature) => return signature_from_bytes(signature.signature()),
        };
    }
}

/// One step of the `EthereumSignTypedData` exchange — the device's next
/// message, classified by wire type.
enum TypedDataStep {
    StructRequest(protos::EthereumTypedDataStructRequest),
    ValueRequest(protos::EthereumTypedDataValueRequest),
    Signature(protos::EthereumTypedDataSignature),
}

/// Sends `message` and classifies the device's response by wire message
/// type. Unlike every other flow in this file, `EthereumSignTypedData`'s
/// responses alternate between three different message types
/// (`EthereumTypedDataStructRequest`, `EthereumTypedDataValueRequest`,
/// `EthereumTypedDataSignature`) depending on protocol phase, which
/// `Trezor::call`'s single-fixed-expected-response-type contract (and so
/// `drive_interaction`, built on top of it) can't express. This
/// reimplements `drive_interaction`'s button/PIN/passphrase handling
/// directly atop `Trezor::call_raw` instead.
fn call_typed_data_step(
    trezor: &mut Trezor,
    message: impl TrezorMessage,
    delegate: &Arc<dyn HardwareDeviceDelegate>,
    runtime: &tokio::runtime::Handle,
) -> Result<TypedDataStep, HardwareError> {
    let into_message_error = |err: protobuf::Error| HardwareError::SigningFailed { reason: err.to_string() };
    let mut resp = trezor.call_raw(message).map_err(map_trezor_error)?;
    let mut pin_attempt: u32 = 0;
    loop {
        match resp.message_type() {
            MessageType::MessageType_EthereumTypedDataStructRequest => {
                return Ok(TypedDataStep::StructRequest(resp.into_message().map_err(into_message_error)?));
            }
            MessageType::MessageType_EthereumTypedDataValueRequest => {
                return Ok(TypedDataStep::ValueRequest(resp.into_message().map_err(into_message_error)?));
            }
            MessageType::MessageType_EthereumTypedDataSignature => {
                return Ok(TypedDataStep::Signature(resp.into_message().map_err(into_message_error)?));
            }
            MessageType::MessageType_Failure => {
                let failure: protos::Failure = resp.into_message().map_err(into_message_error)?;
                return Err(map_failure(&failure));
            }
            MessageType::MessageType_ButtonRequest => {
                runtime.block_on(delegate.waiting_for_confirmation(HardwareButtonRequest::Other {
                    description: "signing the typed data".to_string(),
                }));
                resp = trezor.call_raw(protos::ButtonAck::new()).map_err(map_trezor_error)?;
            }
            MessageType::MessageType_PinMatrixRequest => {
                pin_attempt += 1;
                let Some(pin) = runtime.block_on(delegate.needs_input(HardwareInputRequest::Pin { attempt: pin_attempt }))
                else {
                    return Err(HardwareError::UserCancelled);
                };
                let mut ack = protos::PinMatrixAck::new();
                ack.set_pin(pin);
                resp = trezor.call_raw(ack).map_err(map_trezor_error)?;
            }
            MessageType::MessageType_PassphraseRequest => {
                // The firmware's legacy `_on_device` request flag (< 2.3.0) no
                // longer exists in the protocol; the host always supplies it.
                let _: protos::PassphraseRequest = resp.into_message().map_err(into_message_error)?;
                let mut ack = protos::PassphraseAck::new();
                let Some(passphrase) = runtime.block_on(delegate.needs_input(HardwareInputRequest::Passphrase)) else {
                    return Err(HardwareError::UserCancelled);
                };
                ack.set_passphrase(passphrase);
                resp = trezor.call_raw(ack).map_err(map_trezor_error)?;
            }
            other => {
                return Err(HardwareError::SigningFailed {
                    reason: format!("unexpected Trezor message type while signing typed data: {other:?}"),
                });
            }
        }
    }
}

fn parse_json(raw: &str) -> Result<serde_json::Value, HardwareError> {
    serde_json::from_str(raw).map_err(|err| HardwareError::SigningFailed {
        reason: format!("invalid typed-data JSON: {err}"),
    })
}

/// The field declarations for `type_name`, as EIP-712 `types[type_name]`
/// — an array of `{"name", "type"}` objects in declaration order, which
/// is the order `EthereumTypedDataValueRequest.member_path` indices are
/// relative to.
fn struct_fields<'a>(types: &'a serde_json::Value, type_name: &str) -> Result<&'a Vec<serde_json::Value>, HardwareError> {
    types.get(type_name).and_then(|value| value.as_array()).ok_or_else(|| HardwareError::SigningFailed {
        reason: format!("typed-data `types` has no definition for `{type_name}`"),
    })
}

fn is_array_type(type_name: &str) -> bool {
    type_name.ends_with(']')
}

fn array_element_type(type_name: &str) -> Result<&str, HardwareError> {
    let open = type_name.rfind('[').ok_or_else(|| HardwareError::SigningFailed {
        reason: format!("malformed array type `{type_name}`"),
    })?;
    Ok(&type_name[..open])
}

/// `None` for a dynamic array (`Type[]`); `Some(n)` for a fixed-size one
/// (`Type[n]`).
fn array_length(type_name: &str) -> Option<u32> {
    if type_name.ends_with("[]") {
        return None;
    }
    let open = type_name.rfind('[')?;
    type_name[open + 1..type_name.len() - 1].parse().ok()
}

fn int_type_byte_size(type_name: &str) -> Result<u32, HardwareError> {
    let digits: String = type_name.chars().filter(char::is_ascii_digit).collect();
    let bits: u32 = digits.parse().map_err(|_| HardwareError::SigningFailed {
        reason: format!("could not parse bit width from integer type `{type_name}`"),
    })?;
    Ok(bits / 8)
}

/// `None` for dynamic `bytes`; `Some(n)` for fixed-size `bytesN`.
fn bytes_type_size(type_name: &str) -> Option<u32> {
    if type_name == "bytes" {
        return None;
    }
    type_name.trim_start_matches("bytes").parse().ok()
}

/// Ports `trezorlib.ethereum.get_field_type` — an EIP-712 field-type
/// string (`"uint256"`, `"Person[]"`, `"MyStruct"`, ...) into the
/// structured `EthereumFieldType` `EthereumTypedDataStructAck` needs,
/// recursively describing array element types.
fn field_type(
    type_name: &str,
    types: &serde_json::Value,
) -> Result<protos::ethereum_typed_data_struct_ack::EthereumFieldType, HardwareError> {
    use protos::ethereum_typed_data_struct_ack::{EthereumDataType, EthereumFieldType};

    let mut field = EthereumFieldType::new();
    if is_array_type(type_name) {
        let entry = field_type(array_element_type(type_name)?, types)?;
        if entry.data_type() == EthereumDataType::ARRAY {
            return Err(HardwareError::SigningFailed { reason: "nested arrays are not supported".to_string() });
        }
        field.set_data_type(EthereumDataType::ARRAY);
        if let Some(length) = array_length(type_name) {
            field.set_size(length);
        }
        field.entry_type = MessageField::some(entry);
    } else if type_name.starts_with("uint") {
        field.set_data_type(EthereumDataType::UINT);
        field.set_size(int_type_byte_size(type_name)?);
    } else if type_name.starts_with("int") {
        field.set_data_type(EthereumDataType::INT);
        field.set_size(int_type_byte_size(type_name)?);
    } else if type_name.starts_with("bytes") {
        field.set_data_type(EthereumDataType::BYTES);
        if let Some(size) = bytes_type_size(type_name) {
            field.set_size(size);
        }
    } else if type_name == "string" {
        field.set_data_type(EthereumDataType::STRING);
    } else if type_name == "bool" {
        field.set_data_type(EthereumDataType::BOOL);
    } else if type_name == "address" {
        field.set_data_type(EthereumDataType::ADDRESS);
    } else if types.get(type_name).is_some() {
        field.set_data_type(EthereumDataType::STRUCT);
        field.set_size(struct_fields(types, type_name)?.len() as u32);
        field.set_struct_name(type_name.to_string());
    } else {
        return Err(HardwareError::SigningFailed { reason: format!("unsupported EIP-712 type `{type_name}`") });
    }
    Ok(field)
}

/// Ports `trezorlib.ethereum.sign_typed_data`'s handling of an
/// `EthereumTypedDataStructRequest` — the members Trezor's trusted
/// screen will display and, later, request values for.
fn struct_members(
    types: &serde_json::Value,
    struct_name: &str,
) -> Result<Vec<protos::ethereum_typed_data_struct_ack::EthereumStructMember>, HardwareError> {
    struct_fields(types, struct_name)?
        .iter()
        .map(|field| {
            let name = field.get("name").and_then(|v| v.as_str()).ok_or_else(|| HardwareError::SigningFailed {
                reason: format!("typed-data struct `{struct_name}` has a field with no name"),
            })?;
            let type_name = field.get("type").and_then(|v| v.as_str()).ok_or_else(|| HardwareError::SigningFailed {
                reason: format!("typed-data struct `{struct_name}` field `{name}` has no type"),
            })?;
            let mut member = protos::ethereum_typed_data_struct_ack::EthereumStructMember::new();
            member.type_ = MessageField::some(field_type(type_name, types)?);
            member.set_name(name.to_string());
            Ok(member)
        })
        .collect()
}

/// Ports `trezorlib.ethereum.sign_typed_data`'s handling of an
/// `EthereumTypedDataValueRequest` — walks `member_path` from the domain
/// (`member_path[0] == 0`) or message (`== 1`) root through nested
/// struct/array members, encoding the leaf value (or, for an array, its
/// length as a big-endian `uint16`) the same way
/// `trezorlib.ethereum.encode_data` does.
fn encode_member_value(
    primary_type: &str,
    domain: &serde_json::Value,
    message: &serde_json::Value,
    member_path: &[u32],
    types: &serde_json::Value,
) -> Result<Vec<u8>, HardwareError> {
    let (mut type_name, mut data) = match member_path.first() {
        Some(0) => ("EIP712Domain".to_string(), domain),
        Some(1) => (primary_type.to_string(), message),
        _ => {
            return Err(HardwareError::SigningFailed {
                reason: "typed-data value request has an invalid root index".to_string(),
            });
        }
    };

    for &index in &member_path[1..] {
        let index = index as usize;
        if let Some(object) = data.as_object() {
            let fields = struct_fields(types, &type_name)?;
            let field = fields.get(index).ok_or_else(|| HardwareError::SigningFailed {
                reason: format!("typed-data struct `{type_name}` has no field at index {index}"),
            })?;
            let field_name = field.get("name").and_then(|v| v.as_str()).unwrap_or_default();
            type_name = field.get("type").and_then(|v| v.as_str()).unwrap_or_default().to_string();
            data = object.get(field_name).ok_or_else(|| HardwareError::SigningFailed {
                reason: format!("typed-data message is missing field `{field_name}`"),
            })?;
        } else if let Some(array) = data.as_array() {
            type_name = array_element_type(&type_name)?.to_string();
            data = array.get(index).ok_or_else(|| HardwareError::SigningFailed {
                reason: format!("typed-data array `{type_name}` has no element at index {index}"),
            })?;
        } else {
            return Err(HardwareError::SigningFailed {
                reason: "typed-data value request path descends into a scalar".to_string(),
            });
        }
    }

    if let Some(array) = data.as_array() {
        return Ok((array.len() as u16).to_be_bytes().to_vec());
    }
    encode_atomic_value(data, &type_name)
}

/// Ports `trezorlib.ethereum.encode_data` for a single atomic (non-array,
/// non-struct) EIP-712 value.
fn encode_atomic_value(value: &serde_json::Value, type_name: &str) -> Result<Vec<u8>, HardwareError> {
    let invalid = |reason: String| HardwareError::SigningFailed { reason };

    if type_name.starts_with("bytes") {
        let hex = value.as_str().ok_or_else(|| invalid(format!("expected a hex string for `{type_name}`")))?;
        decode_hex_value(hex)
    } else if type_name == "string" {
        let string = value.as_str().ok_or_else(|| invalid("expected a string value".to_string()))?;
        Ok(string.as_bytes().to_vec())
    } else if type_name.starts_with("uint") {
        let byte_length = int_type_byte_size(type_name)? as usize;
        let magnitude = parse_u256(&scalar_to_string(value)?).map_err(invalid)?;
        Ok(magnitude.to_be_bytes::<32>()[32 - byte_length..].to_vec())
    } else if type_name.starts_with("int") {
        let byte_length = int_type_byte_size(type_name)? as usize;
        let magnitude = parse_i256(&scalar_to_string(value)?).map_err(invalid)?;
        Ok(magnitude.to_be_bytes::<32>()[32 - byte_length..].to_vec())
    } else if type_name == "bool" {
        let boolean = value.as_bool().ok_or_else(|| invalid(format!("expected a bool value, got {value}")))?;
        Ok(vec![boolean as u8])
    } else if type_name == "address" {
        let address = value.as_str().ok_or_else(|| invalid("expected a hex address string".to_string()))?;
        decode_hex_value(address)
    } else {
        Err(invalid(format!("unsupported data type for direct field encoding: {type_name}")))
    }
}

fn scalar_to_string(value: &serde_json::Value) -> Result<String, HardwareError> {
    match value {
        serde_json::Value::String(s) => Ok(s.clone()),
        serde_json::Value::Number(n) => Ok(n.to_string()),
        other => Err(HardwareError::SigningFailed { reason: format!("expected a numeric value, got {other}") }),
    }
}

fn decode_hex_value(value: &str) -> Result<Vec<u8>, HardwareError> {
    hex::decode(value.trim_start_matches("0x").trim_start_matches("0X"))
        .map_err(|err| HardwareError::SigningFailed { reason: format!("invalid hex value `{value}`: {err}") })
}

fn parse_u256(text: &str) -> Result<alloy_primitives::U256, String> {
    if let Some(hex) = text.strip_prefix("0x").or_else(|| text.strip_prefix("0X")) {
        alloy_primitives::U256::from_str_radix(hex, 16).map_err(|err| err.to_string())
    } else {
        alloy_primitives::U256::from_str_radix(text, 10).map_err(|err| err.to_string())
    }
}

fn parse_i256(text: &str) -> Result<alloy_primitives::I256, String> {
    text.parse::<alloy_primitives::I256>().map_err(|err| err.to_string())
}

/// Drives Trezor's `TronSignTx` → contract → `TronSignature` exchange for
/// native transfers, smart-contract calls and Stake 2.0 stake/unstake/
/// withdraw. The device displays these structured fields before signing.
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
        walletkit_hardware::TronContract::TriggerSmartContract { owner_address, contract_address, call_value, data } => {
            let mut contract = protos::TronTriggerSmartContract::new();
            contract.set_owner_address(owner_address);
            contract.set_contract_address(contract_address);
            // Only a non-zero value: proto3 omits the default, and the
            // device's re-serialized raw data must match the original.
            if let Some(call_value) = call_value.filter(|value| *value > 0) {
                contract.set_call_value(call_value);
            }
            contract.set_data(data);
            drive_interaction(
                trezor.call(contract, Box::new(|_, message: protos::TronSignature| Ok(message))),
                delegate,
                runtime,
                &HardwareButtonRequest::ConfirmTransaction,
            )?
        }
        walletkit_hardware::TronContract::FreezeBalanceV2 { owner_address, balance, resource } => {
            let mut contract = protos::TronFreezeBalanceV2Contract::new();
            contract.set_owner_address(owner_address);
            contract.set_balance(balance);
            contract.set_resource(tron_resource_code(resource));
            drive_interaction(
                trezor.call(contract, Box::new(|_, message: protos::TronSignature| Ok(message))),
                delegate,
                runtime,
                &HardwareButtonRequest::ConfirmTransaction,
            )?
        }
        walletkit_hardware::TronContract::UnfreezeBalanceV2 { owner_address, balance, resource } => {
            let mut contract = protos::TronUnfreezeBalanceV2Contract::new();
            contract.set_owner_address(owner_address);
            contract.set_balance(balance);
            contract.set_resource(tron_resource_code(resource));
            drive_interaction(
                trezor.call(contract, Box::new(|_, message: protos::TronSignature| Ok(message))),
                delegate,
                runtime,
                &HardwareButtonRequest::ConfirmTransaction,
            )?
        }
        walletkit_hardware::TronContract::WithdrawExpireUnfreeze { owner_address } => {
            let mut contract = protos::TronWithdrawUnfreeze::new();
            contract.set_owner_address(owner_address);
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

/// The firmware omits `BANDWIDTH` (the proto3 default) when it
/// re-serializes, matching java-tron/TronWeb, so it's always safe to set.
fn tron_resource_code(resource: walletkit_hardware::TronResource) -> protos::TronResourceCode {
    match resource {
        walletkit_hardware::TronResource::Bandwidth => protos::TronResourceCode::BANDWIDTH,
        walletkit_hardware::TronResource::Energy => protos::TronResourceCode::ENERGY,
    }
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

/// Runs on the device's worker thread. Sends `SolanaSignMessage` with the
/// raw message bytes and returns the raw ed25519 signature — one round
/// trip, no streaming, mirroring `ethereum_sign_message`'s shape rather
/// than `solana_sign_tx`'s (which carries token-account metadata this
/// off-chain-message flow has no equivalent of).
pub(super) fn solana_sign_message(
    trezor: &mut Trezor,
    path: &[HardwarePathSegment],
    message: String,
    signers: Vec<Vec<u8>>,
    delegate: &Arc<dyn HardwareDeviceDelegate>,
    runtime: &tokio::runtime::Handle,
) -> Result<Vec<u8>, HardwareError> {
    let mut offchain = protos::SolanaOffchainMessageV1::new();
    offchain.set_message(message);
    offchain.signers = signers;

    let mut req = protos::SolanaSignMessage::new();
    req.address_n = path.iter().map(HardwarePathSegment::to_address_n).collect();
    req.message = Some(offchain).into();

    let resp = drive_interaction(
        trezor.call(req, Box::new(|_, m: protos::SolanaMessageSignature| Ok(m))),
        delegate,
        runtime,
        &HardwareButtonRequest::Other { description: "signing the message".to_string() },
    )?;

    if !resp.has_signature() {
        return Err(HardwareError::SigningFailed { reason: "Trezor returned an empty Solana message signature".to_string() });
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

    // -----------------------------------------------------------------------
    // Cardano dApp transaction/message mapping (pure, no device needed)
    // -----------------------------------------------------------------------

    fn segment(index: u32, hardened: bool) -> HardwarePathSegment {
        HardwarePathSegment { index, hardened }
    }

    fn cardano_path(role: u32) -> Vec<HardwarePathSegment> {
        vec![segment(1852, true), segment(1815, true), segment(0, true), segment(role, false), segment(0, false)]
    }

    fn dapp_output() -> CardanoDappOutput {
        CardanoDappOutput { address: "addr1qx".to_string(), assets: vec![], datum: None, lovelace: 2_000_000, post_alonzo: false, reference_script: None }
    }

    fn dapp_request() -> CardanoDappTxRequest {
        CardanoDappTxRequest {
            auxiliary_data_hash: None,
            certificates: vec![],
            collateral_inputs: vec![],
            collateral_return: None,
            fee: 170_000,
            include_network_id: false,
            inputs: vec![walletkit_hardware::CardanoTxInput { output_index: 3, tx_hash: vec![1; 32] }],
            mint: vec![],
            network_id: 1,
            outputs: vec![dapp_output()],
            protocol_magic: 764_824_073,
            reference_inputs: vec![],
            required_signers: vec![],
            script_data_hash: None,
            tag_cbor_sets: true,
            total_collateral: None,
            ttl: Some(500),
            unsupported_content: vec![],
            validity_start: None,
            withdrawals: vec![],
            witness_paths: vec![cardano_path(0)],
        }
    }

    #[test]
    fn plan_maps_init_fields() {
        let mut request = dapp_request();
        request.validity_start = Some(10);
        request.include_network_id = true;
        request.auxiliary_data_hash = Some(vec![7; 32]);
        let (init, items) = plan_dapp_tx(&request).unwrap();
        assert_eq!(init.signing_mode(), protos::CardanoTxSigningMode::ORDINARY_TRANSACTION);
        assert_eq!((init.inputs_count(), init.outputs_count(), init.fee(), init.ttl()), (1, 1, 170_000, 500));
        assert_eq!(init.validity_interval_start(), 10);
        assert!(init.include_network_id() && init.has_auxiliary_data() && init.tag_cbor_sets());
        assert_eq!(init.witness_requests_count(), 1);
        assert_eq!(init.derivation_type(), protos::CardanoDerivationType::ICARUS);
        assert!(matches!(items.last(), Some(CardanoTxItem::AuxiliaryData(_))));
    }

    #[test]
    fn plan_orders_items_as_the_firmware_consumes_them() {
        let mut request = dapp_request();
        request.script_data_hash = Some(vec![3; 32]);
        request.certificates = vec![CardanoCertificate {
            credential: CardanoCredential::Path(cardano_path(2)),
            deposit: None,
            drep: None,
            kind: CardanoCertificateKind::StakeDelegation,
            pool: Some(vec![9; 28]),
        }];
        request.withdrawals = vec![walletkit_hardware::CardanoWithdrawal { amount: 4, credential: CardanoCredential::ScriptHash(vec![8; 28]) }];
        request.mint = vec![walletkit_hardware::CardanoMintGroup {
            policy_id: vec![2; 28],
            tokens: vec![walletkit_hardware::CardanoMintToken { amount: -5, name: b"t".to_vec() }],
        }];
        request.collateral_inputs = vec![walletkit_hardware::CardanoTxInput { output_index: 0, tx_hash: vec![4; 32] }];
        request.required_signers = vec![CardanoRequiredSigner::KeyHash(vec![6; 28])];
        request.collateral_return = Some(dapp_output());
        request.total_collateral = Some(3_000_000);
        request.reference_inputs = vec![walletkit_hardware::CardanoTxInput { output_index: 1, tx_hash: vec![5; 32] }];

        let (init, items) = plan_dapp_tx(&request).unwrap();
        assert_eq!(init.signing_mode(), protos::CardanoTxSigningMode::PLUTUS_TRANSACTION);
        assert_eq!(init.script_data_hash(), &[3; 32][..]);
        assert_eq!(init.total_collateral(), 3_000_000);
        assert!(init.has_collateral_return());
        let order: Vec<&str> = items
            .iter()
            .map(|item| match item {
                CardanoTxItem::AssetGroup(_) => "group",
                CardanoTxItem::AuxiliaryData(_) => "aux",
                CardanoTxItem::CollateralInput(_) => "collateral",
                CardanoTxItem::Certificate(_) => "certificate",
                CardanoTxItem::InlineDatumChunk(_) => "datum",
                CardanoTxItem::Input(_) => "input",
                CardanoTxItem::Mint(_) => "mint",
                CardanoTxItem::Output(_) => "output",
                CardanoTxItem::ReferenceInput(_) => "reference",
                CardanoTxItem::ReferenceScriptChunk(_) => "script",
                CardanoTxItem::RequiredSigner(_) => "signer",
                CardanoTxItem::Token(_) => "token",
                CardanoTxItem::Withdrawal(_) => "withdrawal",
            })
            .collect();
        assert_eq!(
            order,
            ["input", "output", "certificate", "withdrawal", "mint", "group", "token", "collateral", "signer", "output", "reference"]
        );
        let CardanoTxItem::Certificate(certificate) = &items[2] else { panic!() };
        assert_eq!(certificate.path, vec![0x8000_073c, 0x8000_0717, 0x8000_0000, 2, 0]);
        let CardanoTxItem::Mint(mint) = &items[4] else { panic!() };
        assert_eq!(mint.asset_groups_count(), 1);
        let CardanoTxItem::Token(token) = &items[6] else { panic!() };
        assert_eq!(token.mint_amount(), -5);
    }

    #[test]
    fn plan_groups_output_assets_and_chunks_datums() {
        let asset = |policy: u8, name: &[u8], quantity| walletkit_hardware::CardanoAsset { name: name.to_vec(), policy_id: vec![policy; 28], quantity };
        let mut request = dapp_request();
        request.outputs = vec![CardanoDappOutput {
            assets: vec![asset(1, b"a", 1), asset(2, b"b", 2), asset(1, b"c", 3)],
            datum: Some(CardanoDatum::Inline(vec![0xaa; 2500])),
            post_alonzo: true,
            reference_script: Some(vec![0xbb; 1025]),
            ..dapp_output()
        }];
        let (_, items) = plan_dapp_tx(&request).unwrap();
        let CardanoTxItem::Output(output) = &items[1] else { panic!() };
        assert_eq!(output.asset_groups_count(), 2);
        assert_eq!(output.format(), protos::CardanoTxOutputSerializationFormat::MAP_BABBAGE);
        assert_eq!((output.inline_datum_size(), output.reference_script_size()), (2500, 1025));
        let datum_chunks: Vec<usize> = items.iter().filter_map(|item| match item { CardanoTxItem::InlineDatumChunk(chunk) => Some(chunk.data().len()), _ => None }).collect();
        let script_chunks: Vec<usize> = items.iter().filter_map(|item| match item { CardanoTxItem::ReferenceScriptChunk(chunk) => Some(chunk.data().len()), _ => None }).collect();
        assert_eq!(datum_chunks, [1024, 1024, 452]);
        assert_eq!(script_chunks, [1024, 1]);
        let CardanoTxItem::AssetGroup(first) = &items[2] else { panic!() };
        assert_eq!((first.policy_id(), first.tokens_count()), (&[1; 28][..], 2));
    }

    #[test]
    fn plan_maps_datum_hash_and_vote_delegation() {
        let mut request = dapp_request();
        request.outputs[0].datum = Some(CardanoDatum::Hash(vec![5; 32]));
        request.certificates = vec![CardanoCertificate {
            credential: CardanoCredential::Path(cardano_path(2)),
            deposit: None,
            drep: Some(CardanoDRep::KeyHash(vec![4; 28])),
            kind: CardanoCertificateKind::VoteDelegation,
            pool: None,
        }];
        let (_, items) = plan_dapp_tx(&request).unwrap();
        let CardanoTxItem::Output(output) = &items[1] else { panic!() };
        assert_eq!(output.datum_hash(), &[5; 32][..]);
        assert_eq!(output.inline_datum_size(), 0);
        let CardanoTxItem::Certificate(certificate) = &items[2] else { panic!() };
        assert_eq!(certificate.type_(), protos::CardanoCertificateType::VOTE_DELEGATION);
        assert_eq!(certificate.drep.type_(), protos::CardanoDRepType::KEY_HASH);
    }

    #[test]
    fn plan_rejects_unsupported_content_before_any_message() {
        let mut request = dapp_request();
        request.unsupported_content = vec!["proposal procedures".to_string()];
        assert!(matches!(plan_dapp_tx(&request), Err(HardwareError::UnsupportedDevice { .. })));
    }

    #[test]
    fn message_plan_streams_raw_payload_size() {
        let request = CardanoMessageRequest {
            address: Some(walletkit_hardware::CardanoMessageAddress {
                address_type: CardanoMessageAddressType::Base,
                network_id: 1,
                path: cardano_path(0),
                protocol_magic: 764_824_073,
                staking_key_hash: None,
                staking_path: cardano_path(2),
            }),
            payload: b"hello".to_vec(),
            prefer_hex_display: true,
            signing_path: cardano_path(0),
        };
        let init = plan_message(&request).unwrap();
        assert_eq!(init.payload_size(), 5);
        assert!(init.prefer_hex_display());
        assert_eq!(init.derivation_type(), protos::CardanoDerivationType::ICARUS);
        assert_eq!(init.signing_path, address_n(&cardano_path(0)));
        assert_eq!(init.address_parameters.address_type(), protos::CardanoAddressType::BASE);
        assert_eq!((init.network_id(), init.protocol_magic()), (1, 764_824_073));
    }

    #[test]
    fn message_plan_without_address_omits_parameters() {
        let request = CardanoMessageRequest { address: None, payload: vec![], prefer_hex_display: false, signing_path: cardano_path(2) };
        let init = plan_message(&request).unwrap();
        assert_eq!(init.payload_size(), 0);
        assert!(init.address_parameters.is_none() && !init.has_network_id());
    }

    #[test]
    fn message_plan_rejects_hash_like_payload_instead_of_hashing() {
        let request = CardanoMessageRequest { address: None, payload: vec![0xff; 28], prefer_hex_display: false, signing_path: cardano_path(0) };
        assert!(matches!(plan_message(&request), Err(HardwareError::SigningFailed { .. })));
    }

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

    // -----------------------------------------------------------------------
    // EIP-712 typed-data struct/value walk (pure logic, no device needed)
    // -----------------------------------------------------------------------

    /// The same worked "Mail" example from the EIP-712 spec used in
    /// `walletkit-ffi`'s `ethereum_message` tests.
    const EIP_712_MAIL_EXAMPLE: &str = r#"{
        "types": {
            "EIP712Domain": [
                {"name": "name", "type": "string"},
                {"name": "version", "type": "string"},
                {"name": "chainId", "type": "uint256"},
                {"name": "verifyingContract", "type": "address"}
            ],
            "Person": [
                {"name": "name", "type": "string"},
                {"name": "wallet", "type": "address"}
            ],
            "Mail": [
                {"name": "from", "type": "Person"},
                {"name": "to", "type": "Person"},
                {"name": "contents", "type": "string"}
            ]
        },
        "primaryType": "Mail",
        "domain": {
            "name": "Ether Mail",
            "version": "1",
            "chainId": 1,
            "verifyingContract": "0xCcCCccccCCCCcCCCCCCcCcCccCcCCCcCcccccccC"
        },
        "message": {
            "from": {"name": "Cow", "wallet": "0xCD2a3d9F938E13CD947Ec05AbC7FE734Df8DD826"},
            "to": {"name": "Bob", "wallet": "0xbBbBBBBbbBBBbbbBbbBbbbbBBbBbbbbBbBbbBBbB"},
            "contents": "Hello, Bob!"
        }
    }"#;

    fn mail_example() -> (serde_json::Value, serde_json::Value, serde_json::Value) {
        let raw: serde_json::Value = serde_json::from_str(EIP_712_MAIL_EXAMPLE).unwrap();
        (raw["types"].clone(), raw["domain"].clone(), raw["message"].clone())
    }

    #[test]
    fn field_type_describes_every_atomic_kind() {
        use protos::ethereum_typed_data_struct_ack::EthereumDataType;
        let (types, _, _) = mail_example();

        assert_eq!(field_type("string", &types).unwrap().data_type(), EthereumDataType::STRING);
        assert_eq!(field_type("bool", &types).unwrap().data_type(), EthereumDataType::BOOL);
        assert_eq!(field_type("address", &types).unwrap().data_type(), EthereumDataType::ADDRESS);

        let uint256 = field_type("uint256", &types).unwrap();
        assert_eq!(uint256.data_type(), EthereumDataType::UINT);
        assert_eq!(uint256.size(), 32);

        let int8 = field_type("int8", &types).unwrap();
        assert_eq!(int8.data_type(), EthereumDataType::INT);
        assert_eq!(int8.size(), 1);

        let bytes32 = field_type("bytes32", &types).unwrap();
        assert_eq!(bytes32.data_type(), EthereumDataType::BYTES);
        assert_eq!(bytes32.size(), 32);

        let dynamic_bytes = field_type("bytes", &types).unwrap();
        assert_eq!(dynamic_bytes.data_type(), EthereumDataType::BYTES);
        assert!(!dynamic_bytes.has_size());
    }

    #[test]
    fn field_type_describes_a_struct_by_its_member_count() {
        let (types, _, _) = mail_example();
        let person = field_type("Person", &types).unwrap();
        assert_eq!(person.data_type(), protos::ethereum_typed_data_struct_ack::EthereumDataType::STRUCT);
        assert_eq!(person.size(), 2);
        assert_eq!(person.struct_name(), "Person");
    }

    #[test]
    fn field_type_describes_a_dynamic_array_of_structs() {
        let (types, _, _) = mail_example();
        let array = field_type("Person[]", &types).unwrap();
        assert_eq!(array.data_type(), protos::ethereum_typed_data_struct_ack::EthereumDataType::ARRAY);
        assert!(!array.has_size());
        assert_eq!(array.entry_type.struct_name(), "Person");
    }

    #[test]
    fn field_type_describes_a_fixed_size_array() {
        let (types, _, _) = mail_example();
        let array = field_type("uint8[4]", &types).unwrap();
        assert_eq!(array.data_type(), protos::ethereum_typed_data_struct_ack::EthereumDataType::ARRAY);
        assert_eq!(array.size(), 4);
    }

    #[test]
    fn field_type_rejects_nested_arrays() {
        let (types, _, _) = mail_example();
        assert!(field_type("uint8[][]", &types).is_err());
    }

    #[test]
    fn field_type_rejects_an_unknown_type_name() {
        let (types, _, _) = mail_example();
        assert!(field_type("NotAType", &types).is_err());
    }

    #[test]
    fn struct_members_matches_the_declared_field_order() {
        let (types, _, _) = mail_example();
        let members = struct_members(&types, "Mail").unwrap();
        let names: Vec<&str> = members.iter().map(|m| m.name()).collect();
        assert_eq!(names, vec!["from", "to", "contents"]);
    }

    #[test]
    fn encode_member_value_reads_the_domain_root_for_index_zero() {
        let (types, domain, message) = mail_example();
        // domain.name is field index 0 of EIP712Domain.
        let value = encode_member_value("Mail", &domain, &message, &[0, 0], &types).unwrap();
        assert_eq!(value, b"Ether Mail");
    }

    #[test]
    fn encode_member_value_reads_the_message_root_for_index_one() {
        let (types, domain, message) = mail_example();
        // message.contents is field index 2 of Mail.
        let value = encode_member_value("Mail", &domain, &message, &[1, 2], &types).unwrap();
        assert_eq!(value, b"Hello, Bob!");
    }

    #[test]
    fn encode_member_value_walks_into_a_nested_struct_field() {
        let (types, domain, message) = mail_example();
        // message.from (field 0 of Mail) .name (field 0 of Person).
        let value = encode_member_value("Mail", &domain, &message, &[1, 0, 0], &types).unwrap();
        assert_eq!(value, b"Cow");
    }

    #[test]
    fn encode_member_value_encodes_an_address_as_raw_bytes() {
        let (types, domain, message) = mail_example();
        // message.from.wallet
        let value = encode_member_value("Mail", &domain, &message, &[1, 0, 1], &types).unwrap();
        assert_eq!(value, hex::decode("CD2a3d9F938E13CD947Ec05AbC7FE734Df8DD826").unwrap());
    }

    #[test]
    fn encode_member_value_encodes_a_uint256_domain_chain_id() {
        let (types, domain, message) = mail_example();
        // domain.chainId
        let value = encode_member_value("Mail", &domain, &message, &[0, 2], &types).unwrap();
        assert_eq!(value.len(), 32);
        assert_eq!(value[31], 1);
        assert!(value[..31].iter().all(|&byte| byte == 0));
    }

    #[test]
    fn encode_member_value_rejects_an_invalid_root_index() {
        let (types, domain, message) = mail_example();
        assert!(encode_member_value("Mail", &domain, &message, &[2], &types).is_err());
    }

    #[test]
    fn encode_atomic_value_encodes_uint256_from_a_decimal_string() {
        let value = serde_json::Value::String("1000000000000000000".to_string());
        let encoded = encode_atomic_value(&value, "uint256").unwrap();
        assert_eq!(encoded.len(), 32);
        let expected = alloy_primitives::U256::from(1_000_000_000_000_000_000u128).to_be_bytes::<32>();
        assert_eq!(encoded, expected.to_vec());
    }

    #[test]
    fn encode_atomic_value_encodes_a_negative_int() {
        let value = serde_json::Value::String("-1".to_string());
        let encoded = encode_atomic_value(&value, "int8").unwrap();
        assert_eq!(encoded, vec![0xff]);
    }

    #[test]
    fn encode_atomic_value_encodes_a_bool() {
        assert_eq!(encode_atomic_value(&serde_json::Value::Bool(true), "bool").unwrap(), vec![1]);
        assert_eq!(encode_atomic_value(&serde_json::Value::Bool(false), "bool").unwrap(), vec![0]);
    }

    #[test]
    fn encode_atomic_value_rejects_an_unsupported_type() {
        let value = serde_json::Value::String("x".to_string());
        assert!(encode_atomic_value(&value, "Person").is_err());
    }
}
