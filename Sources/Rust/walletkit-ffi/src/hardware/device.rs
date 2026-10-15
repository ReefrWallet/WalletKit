use std::sync::Arc;

use walletkit_hardware as hw;

use crate::{
    blockchain_clients::{
        BitcoinNetworkFfi, EthereumEIP1559SignTxFfi, EthereumEIP1559SignatureFfi, EthereumSignTxFfi,
        EthereumSignatureFfi, EthereumTypedDataFieldsFfi,
    },
    common::{BigIntFfi, CurveFfi, DerivationPathFfi},
    errors::WalletKitErrorFfi,
    keys::PublicKeyFfi,
};

use super::types::HardwareDeviceInfoFfi;

#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct CardanoSignTxFfi {
    pub body_hash: Vec<u8>,
    pub fee: u64,
    pub inputs: Vec<CardanoInputFfi>,
    pub network_id: u8,
    pub outputs: Vec<CardanoOutputFfi>,
    pub protocol_magic: u32,
    pub ttl: Option<u64>,
    pub witness_paths: Vec<DerivationPathFfi>,
}

#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct CardanoInputFfi { pub output_index: u32, pub tx_hash: Vec<u8> }
#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct CardanoOutputFfi { pub address: String, pub assets: Vec<HardwareCardanoAssetFfi>, pub lovelace: u64 }
#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct HardwareCardanoAssetFfi { pub name: Vec<u8>, pub policy_id: Vec<u8>, pub quantity: u64 }

/// A connected hardware wallet — a source of public keys and signatures,
/// read from / produced by the device rather than derived or computed
/// in-process. Obtained from `HardwareDeviceManagerFfi::connect`.
#[derive(uniffi::Object)]
pub struct HardwareDeviceFfi {
    pub(super) inner: Arc<dyn hw::HardwareDevice>,
}

#[uniffi::export(async_runtime = "tokio")]
impl HardwareDeviceFfi {
    /// Static metadata describing this device.
    pub fn info(&self) -> HardwareDeviceInfoFfi {
        self.inner.info().into()
    }

    /// Whether this device is still connected.
    pub fn is_connected(&self) -> bool {
        self.inner.is_connected()
    }

    /// Reads the public key at `path` for `curve` from the device.
    ///
    /// Throws `.unsupportedDevice` for a curve the device can't derive
    /// (Trezor only supports secp256k1 today), `.deviceDisconnected` if
    /// the device has gone away, `.userCancelled`/`.userRejectedOnDevice`
    /// if the user backs out of a PIN/passphrase/confirmation prompt, or
    /// other hardware-wallet `WalletKitError` cases.
    pub async fn public_key(
        &self,
        path: DerivationPathFfi,
        curve: CurveFfi,
    ) -> Result<Arc<PublicKeyFfi>, WalletKitErrorFfi> {
        let segments = to_hardware_segments(&path);
        let raw_bytes = self.inner.public_key(segments, to_hardware_curve(curve)).await?;
        Ok(Arc::new(PublicKeyFfi::new(curve, raw_bytes)))
    }

    /// Signs an Ethereum transaction on the device, showing `tx`'s fields
    /// (as `decode_signing_data` on `EthereumSignerFfi` recovered them)
    /// on its trusted screen for the user to confirm.
    ///
    /// Throws `.userCancelled`/`.userRejectedOnDevice` if the user backs
    /// out, `.deviceDisconnected` if the device goes away mid-signature,
    /// or `.signingFailed` if the device reports a protocol-level failure.
    pub async fn ethereum_sign_tx(
        &self,
        path: DerivationPathFfi,
        tx: EthereumSignTxFfi,
    ) -> Result<EthereumSignatureFfi, WalletKitErrorFfi> {
        let segments = to_hardware_segments(&path);
        let fields = to_ethereum_tx_fields(tx)?;
        let signature = self.inner.ethereum_sign_tx(segments, fields).await?;
        Ok(EthereumSignatureFfi { v: signature.v, r: signature.r, s: signature.s })
    }

    /// Signs an EIP-1559 (type-2) Ethereum transaction on the device, showing
    /// `tx`'s fields on its trusted screen for the user to confirm.
    ///
    /// Throws `.userCancelled`/`.userRejectedOnDevice` if the user backs out,
    /// `.deviceDisconnected` if the device goes away mid-signature, or
    /// `.signingFailed` if the device reports a protocol-level failure.
    pub async fn ethereum_sign_tx_eip1559(
        &self,
        path: DerivationPathFfi,
        tx: EthereumEIP1559SignTxFfi,
    ) -> Result<EthereumEIP1559SignatureFfi, WalletKitErrorFfi> {
        let segments = to_hardware_segments(&path);
        let fields = to_ethereum_eip1559_tx_fields(tx)?;
        let signature = self.inner.ethereum_sign_tx_eip1559(segments, fields).await?;
        Ok(EthereumEIP1559SignatureFfi { y_parity: signature.y_parity, r: signature.r, s: signature.s })
    }

    /// Signs an EIP-191 personal message on the device, returning the
    /// same 65-byte `r ‖ s ‖ v` shape (legacy 27/28 `v`) `EthereumSignerFfi
    /// ::sign_digest` returns for the software path — so
    /// `EthereumTrezorSigner`'s `MessageSigner` conformance can hand back
    /// either one without further reshaping.
    ///
    /// Throws `.userCancelled`/`.userRejectedOnDevice` if the user backs
    /// out, `.deviceDisconnected` if the device goes away mid-signature,
    /// or `.signingFailed` if the device reports a protocol-level failure.
    pub async fn ethereum_sign_message(&self, path: DerivationPathFfi, message: Vec<u8>) -> Result<Vec<u8>, WalletKitErrorFfi> {
        let segments = to_hardware_segments(&path);
        let signature = self.inner.ethereum_sign_message(segments, message).await?;
        encode_message_signature(signature)
    }

    /// Signs an EIP-712 typed-data payload on the device — the full
    /// interactive `EthereumSignTypedData` struct/value walk on Trezor
    /// Model T/Safe, or `EthereumSignTypedHash` (over `fields`'s two
    /// hashes) on Trezor One, whose firmware doesn't implement the full
    /// flow. Returns the same 65-byte shape `ethereum_sign_message` does.
    ///
    /// Throws `.userCancelled`/`.userRejectedOnDevice` if the user backs
    /// out, `.deviceDisconnected` if the device goes away mid-signature,
    /// or `.signingFailed` if the device reports a protocol-level failure
    /// or `fields`' JSON is malformed.
    pub async fn ethereum_sign_typed_data(
        &self,
        path: DerivationPathFfi,
        fields: EthereumTypedDataFieldsFfi,
    ) -> Result<Vec<u8>, WalletKitErrorFfi> {
        let segments = to_hardware_segments(&path);
        let fields = hw::EthereumTypedDataFields {
            primary_type: fields.primary_type,
            types_json: fields.types_json,
            domain_json: fields.domain_json,
            message_json: fields.message_json,
            domain_separator_hash: fields.domain_separator_hash,
            message_hash: fields.message_hash,
        };
        let signature = self.inner.ethereum_sign_typed_data(segments, fields).await?;
        encode_message_signature(signature)
    }

    /// Signs the raw TronGrid transaction response on the device:
    /// `TransferContract`, `TriggerSmartContract` and the Stake 2.0
    /// `FreezeBalanceV2`/`UnfreezeBalanceV2`/`WithdrawExpireUnfreeze`.
    pub async fn tron_sign_tx(
        &self,
        path: DerivationPathFfi,
        transaction: String,
    ) -> Result<Vec<u8>, WalletKitErrorFfi> {
        let fields = to_tron_tx_fields(&transaction)?;
        self.inner.tron_sign_tx(to_hardware_segments(&path), fields).await.map_err(Into::into)
    }

    /// Signs a Solana transaction message on the device. `transaction` is
    /// the same JSON envelope `SolanaTransactionBuilder`/`SolanaPKeySigner`
    /// use on the software path — a base64 `message` field plus a
    /// `tokenAccounts` array describing any SPL accounts the message
    /// touches, so the device's trusted screen can show mint/owner rather
    /// than opaque token-account addresses. Returns the raw 64-byte
    /// ed25519 signature over the decoded message.
    pub async fn solana_sign_tx(
        &self,
        path: DerivationPathFfi,
        transaction: String,
    ) -> Result<Vec<u8>, WalletKitErrorFfi> {
        let fields = to_solana_tx_fields(&transaction)?;
        self.inner.solana_sign_tx(to_hardware_segments(&path), fields).await.map_err(Into::into)
    }

    /// Signs a Solana off-chain message (OCMS v1) on the device: a UTF-8
    /// `message` plus the 32-byte `signers` keys (which must include the
    /// key at `path`). Returns the raw 64-byte ed25519 signature over the
    /// firmware's own serialization of that structure, not the raw text.
    pub async fn solana_sign_message(
        &self,
        path: DerivationPathFfi,
        message: String,
        signers: Vec<Vec<u8>>,
    ) -> Result<Vec<u8>, WalletKitErrorFfi> {
        let segments = to_hardware_segments(&path);
        self.inner.solana_sign_message(segments, message, signers).await.map_err(Into::into)
    }

    /// Reads the Cardano Icarus/CIP-1852 account xpub at `path`.
    pub async fn cardano_xpub(&self, path: DerivationPathFfi) -> Result<String, WalletKitErrorFfi> {
        let xpub = self.inner.cardano_xpub(to_hardware_segments(&path)).await?;
        crate::blockchain_clients::cardano::normalize_account_xpub(&xpub)
    }

    /// Signs a Cardano transaction through Trezor's structured transaction
    /// protocol. The device's reconstructed body hash is verified before any
    /// returned witnesses are accepted.
    pub async fn cardano_sign_tx(
        &self,
        tx: CardanoSignTxFfi,
    ) -> Result<Vec<crate::blockchain_clients::CardanoWitnessFfi>, WalletKitErrorFfi> {
        let fields = hw::CardanoTxFields {
            body_hash: tx.body_hash,
            fee: tx.fee,
            inputs: tx.inputs.into_iter().map(|input| hw::CardanoTxInput {
                output_index: input.output_index,
                tx_hash: input.tx_hash,
            }).collect(),
            network_id: tx.network_id,
            outputs: tx.outputs.into_iter().map(|output| hw::CardanoTxOutput {
                address: output.address,
                assets: output.assets.into_iter().map(|asset| hw::CardanoAsset {
                    name: asset.name,
                    policy_id: asset.policy_id,
                    quantity: asset.quantity,
                }).collect(),
                lovelace: output.lovelace,
            }).collect(),
            protocol_magic: tx.protocol_magic,
            ttl: tx.ttl,
            witness_paths: tx.witness_paths.iter().map(to_hardware_segments).collect(),
        };
        Ok(self.inner.cardano_sign_tx(fields).await?.into_iter().map(|witness| crate::blockchain_clients::CardanoWitnessFfi {
            public_key: witness.public_key,
            signature: witness.signature,
        }).collect())
    }

    /// Reads the account-level extended public key (xpub, with its chain
    /// code) at `path` from the device, Base58Check-encoded with mainnet
    /// (`xpub`) version bytes regardless of which Bitcoin network `path`
    /// is actually for — enough to build a `BitcoinDescriptorFfi` that
    /// derives every external/change address under `path` without a
    /// further device round-trip.
    ///
    /// Throws `.userCancelled`/`.userRejectedOnDevice` if the user backs
    /// out, or `.deviceDisconnected` if the device goes away mid-request.
    pub async fn bitcoin_xpub(&self, path: DerivationPathFfi) -> Result<String, WalletKitErrorFfi> {
        let segments = to_hardware_segments(&path);
        let xpub = self.inner.bitcoin_xpub(segments).await?;
        Ok(xpub)
    }

    /// Signs a Bitcoin PSBT (built by `bitcoin_build_unsigned_psbt`) on the
    /// device via its interactive `SignTx`/`TxRequest`/`TxAck` flow, driven
    /// entirely from the PSBT's own `bip32_derivation`/`tap_key_origins`
    /// fields. Returns the finalized, consensus-serialized raw transaction.
    ///
    /// Throws `.userCancelled`/`.userRejectedOnDevice` if the user backs
    /// out, `.deviceDisconnected` if the device goes away mid-signature, or
    /// `.signingFailed` if the device reports a protocol-level failure.
    pub async fn bitcoin_sign_psbt(
        &self,
        psbt: Vec<u8>,
        network: BitcoinNetworkFfi,
    ) -> Result<Vec<u8>, WalletKitErrorFfi> {
        let raw_tx = self.inner.bitcoin_sign_psbt(psbt, to_hardware_bitcoin_network(network)).await?;
        Ok(raw_tx)
    }

    /// Disconnects from this device.
    pub async fn disconnect(&self) {
        self.inner.disconnect().await
    }
}

fn to_hardware_segments(path: &DerivationPathFfi) -> Vec<hw::HardwarePathSegment> {
    path.segments.iter().map(|segment| hw::HardwarePathSegment { index: segment.index, hardened: segment.hardened }).collect()
}

fn to_hardware_curve(curve: CurveFfi) -> hw::HardwareCurve {
    match curve {
        CurveFfi::Secp256k1 => hw::HardwareCurve::Secp256k1,
        CurveFfi::Ed25519 => hw::HardwareCurve::Ed25519,
    }
}

fn to_hardware_bitcoin_network(network: BitcoinNetworkFfi) -> hw::HardwareBitcoinNetwork {
    match network {
        BitcoinNetworkFfi::Mainnet => hw::HardwareBitcoinNetwork::Mainnet,
        BitcoinNetworkFfi::Testnet => hw::HardwareBitcoinNetwork::Testnet,
        BitcoinNetworkFfi::Signet => hw::HardwareBitcoinNetwork::Signet,
        BitcoinNetworkFfi::Regtest => hw::HardwareBitcoinNetwork::Regtest,
    }
}

fn to_ethereum_tx_fields(tx: EthereumSignTxFfi) -> Result<hw::EthereumTxFields, WalletKitErrorFfi> {
    Ok(hw::EthereumTxFields {
        nonce: nonnegative_be_bytes(&tx.nonce)?,
        gas_price: nonnegative_be_bytes(&tx.gas_price)?,
        gas_limit: nonnegative_be_bytes(&tx.gas_limit)?,
        to: tx.to,
        value: nonnegative_be_bytes(&tx.value)?,
        data: tx.data,
        chain_id: tx.chain_id,
    })
}

fn to_ethereum_eip1559_tx_fields(tx: EthereumEIP1559SignTxFfi) -> Result<hw::EthereumEIP1559TxFields, WalletKitErrorFfi> {
    Ok(hw::EthereumEIP1559TxFields {
        nonce: nonnegative_be_bytes(&tx.nonce)?,
        max_priority_fee_per_gas: nonnegative_be_bytes(&tx.max_priority_fee_per_gas)?,
        max_fee_per_gas: nonnegative_be_bytes(&tx.max_fee_per_gas)?,
        gas_limit: nonnegative_be_bytes(&tx.gas_limit)?,
        to: tx.to,
        value: nonnegative_be_bytes(&tx.value)?,
        data: tx.data,
        chain_id: tx.chain_id,
    })
}

fn to_tron_tx_fields(transaction: &str) -> Result<hw::TronTxFields, WalletKitErrorFfi> {
    let value: serde_json::Value = serde_json::from_str(transaction).map_err(|error| WalletKitErrorFfi::SigningFailed {
        reason: format!("invalid Tron transaction JSON: {error}"),
    })?;
    let raw = value.get("raw_data").unwrap_or(&value);
    let bytes = |name: &str| -> Result<Vec<u8>, WalletKitErrorFfi> {
        let value = raw.get(name).and_then(serde_json::Value::as_str).ok_or_else(|| WalletKitErrorFfi::SigningFailed {
            reason: format!("Tron transaction is missing {name}"),
        })?;
        hex::decode(value).map_err(|_| WalletKitErrorFfi::SigningFailed { reason: format!("invalid Tron {name} hex") })
    };
    let number = |name: &str| -> Result<u64, WalletKitErrorFfi> {
        raw.get(name).and_then(serde_json::Value::as_u64).ok_or_else(|| WalletKitErrorFfi::SigningFailed {
            reason: format!("Tron transaction is missing {name}"),
        })
    };
    let contract = raw.get("contract").and_then(serde_json::Value::as_array).and_then(|contracts| contracts.first())
        .ok_or_else(|| WalletKitErrorFfi::SigningFailed { reason: "Tron transaction has no contract".to_string() })?;
    let payload = contract.pointer("/parameter/value").ok_or_else(|| WalletKitErrorFfi::SigningFailed {
        reason: "Tron transaction contract has no value".to_string(),
    })?;
    let address = |value: &serde_json::Value, name: &str| -> Result<Vec<u8>, WalletKitErrorFfi> {
        let text = value.get(name).and_then(serde_json::Value::as_str).ok_or_else(|| WalletKitErrorFfi::SigningFailed {
            reason: format!("Tron contract is missing {name}"),
        })?;
        hex::decode(text).map_err(|_| WalletKitErrorFfi::SigningFailed { reason: format!("invalid Tron {name} hex") })
    };
    let owner_address = address(payload, "owner_address")?;
    let contract = match contract.get("type").and_then(serde_json::Value::as_str) {
        Some("TransferContract") => hw::TronContract::Transfer {
            owner_address,
            to_address: address(payload, "to_address")?,
            amount: payload.get("amount").and_then(serde_json::Value::as_u64).ok_or_else(|| WalletKitErrorFfi::SigningFailed {
                reason: "Tron transfer has an invalid amount".to_string(),
            })?,
        },
        Some("TriggerSmartContract") => hw::TronContract::TriggerSmartContract {
            owner_address,
            contract_address: address(payload, "contract_address")?,
            call_value: match payload.get("call_value") {
                None => None,
                Some(value) => Some(value.as_u64().ok_or_else(|| WalletKitErrorFfi::SigningFailed {
                    reason: "Tron contract call has an invalid call_value".to_string(),
                })?),
            },
            data: address(payload, "data")?,
        },
        Some("FreezeBalanceV2Contract") => hw::TronContract::FreezeBalanceV2 {
            owner_address,
            balance: tron_optional_amount(payload, "frozen_balance")?,
            resource: tron_resource(payload)?,
        },
        Some("UnfreezeBalanceV2Contract") => hw::TronContract::UnfreezeBalanceV2 {
            owner_address,
            balance: tron_optional_amount(payload, "unfreeze_balance")?,
            resource: tron_resource(payload)?,
        },
        Some("WithdrawExpireUnfreezeContract") => hw::TronContract::WithdrawExpireUnfreeze { owner_address },
        _ => return Err(WalletKitErrorFfi::UnsupportedDevice {
            reason: "Trezor Tron signing supports only transfers, smart-contract calls and Stake 2.0 stake/unstake/withdraw".to_string(),
        }),
    };
    Ok(hw::TronTxFields {
        ref_block_bytes: bytes("ref_block_bytes")?,
        ref_block_hash: bytes("ref_block_hash")?,
        expiration: number("expiration")?,
        timestamp: number("timestamp")?,
        fee_limit: raw.get("fee_limit").and_then(serde_json::Value::as_u64),
        data: raw.get("data").and_then(serde_json::Value::as_str).map(hex::decode).transpose().map_err(|_| WalletKitErrorFfi::SigningFailed { reason: "invalid Tron memo hex".to_string() })?,
        contract,
    })
}

/// A SUN amount that TronGrid omits when zero (proto3 default).
fn tron_optional_amount(payload: &serde_json::Value, name: &str) -> Result<u64, WalletKitErrorFfi> {
    match payload.get(name) {
        None => Ok(0),
        Some(value) => value.as_u64().ok_or_else(|| WalletKitErrorFfi::SigningFailed {
            reason: format!("Tron contract has an invalid {name}"),
        }),
    }
}

/// `resource` as TronGrid writes it: absent for `BANDWIDTH` (proto3
/// default), otherwise the enum name. Trezor has no `TRON_POWER`.
fn tron_resource(payload: &serde_json::Value) -> Result<hw::TronResource, WalletKitErrorFfi> {
    match payload.get("resource").map(|value| value.as_str()) {
        None | Some(Some("BANDWIDTH")) => Ok(hw::TronResource::Bandwidth),
        Some(Some("ENERGY")) => Ok(hw::TronResource::Energy),
        _ => Err(WalletKitErrorFfi::UnsupportedDevice {
            reason: "Trezor can stake only for bandwidth or energy".to_string(),
        }),
    }
}

fn to_solana_tx_fields(transaction: &str) -> Result<hw::SolanaTxFields, WalletKitErrorFfi> {
    use base64::Engine;

    let value: serde_json::Value = serde_json::from_str(transaction).map_err(|error| WalletKitErrorFfi::SigningFailed {
        reason: format!("invalid Solana transaction JSON: {error}"),
    })?;
    let message_b64 = value.get("message").and_then(serde_json::Value::as_str).ok_or_else(|| WalletKitErrorFfi::SigningFailed {
        reason: "Solana transaction is missing message".to_string(),
    })?;
    let serialized_message = base64::engine::general_purpose::STANDARD.decode(message_b64).map_err(|error| {
        WalletKitErrorFfi::SigningFailed { reason: format!("invalid Solana message base64: {error}") }
    })?;

    let text = |account: &serde_json::Value, name: &str| -> Result<String, WalletKitErrorFfi> {
        account.get(name).and_then(serde_json::Value::as_str).map(str::to_string).ok_or_else(|| {
            WalletKitErrorFfi::SigningFailed { reason: format!("Solana token account entry is missing {name}") }
        })
    };
    let token_accounts = value
        .get("tokenAccounts")
        .and_then(serde_json::Value::as_array)
        .cloned()
        .unwrap_or_default()
        .into_iter()
        .map(|account| {
            Ok(hw::SolanaTokenAccountInfo {
                base_address: text(&account, "baseAddress")?,
                token_program: text(&account, "tokenProgram")?,
                token_mint: text(&account, "tokenMint")?,
                token_account: text(&account, "tokenAccount")?,
            })
        })
        .collect::<Result<Vec<_>, WalletKitErrorFfi>>()?;

    Ok(hw::SolanaTxFields { serialized_message, token_accounts })
}

/// Encodes the `raw_data` protobuf bytes that a Tron node and Trezor sign.
/// Kept beside the hardware parser so the signed message can be verified
/// against the device public key without a second JSON interpretation.
#[uniffi::export]
pub fn tron_raw_data(transaction: String) -> Result<Vec<u8>, WalletKitErrorFfi> {
    let fields = to_tron_tx_fields(&transaction)?;
    let mut output = Vec::new();
    let contract = match fields.contract {
        hw::TronContract::Transfer { owner_address, to_address, amount } => {
            let mut transfer = Vec::new();
            wire_bytes(&mut transfer, 1, &owner_address);
            wire_bytes(&mut transfer, 2, &to_address);
            wire_varint(&mut transfer, 3, amount);
            (1, "type.googleapis.com/protocol.TransferContract", transfer)
        }
        hw::TronContract::TriggerSmartContract { owner_address, contract_address, call_value, data } => {
            let mut trigger = Vec::new();
            wire_bytes(&mut trigger, 1, &owner_address);
            wire_bytes(&mut trigger, 2, &contract_address);
            if let Some(call_value) = call_value.filter(|value| *value > 0) {
                wire_varint(&mut trigger, 3, call_value);
            }
            wire_bytes(&mut trigger, 4, &data);
            (31, "type.googleapis.com/protocol.TriggerSmartContract", trigger)
        }
        hw::TronContract::FreezeBalanceV2 { owner_address, balance, resource } => {
            (54, "type.googleapis.com/protocol.FreezeBalanceV2Contract", stake_contract(&owner_address, balance, resource))
        }
        hw::TronContract::UnfreezeBalanceV2 { owner_address, balance, resource } => {
            (55, "type.googleapis.com/protocol.UnfreezeBalanceV2Contract", stake_contract(&owner_address, balance, resource))
        }
        hw::TronContract::WithdrawExpireUnfreeze { owner_address } => {
            let mut withdraw = Vec::new();
            wire_bytes(&mut withdraw, 1, &owner_address);
            (56, "type.googleapis.com/protocol.WithdrawExpireUnfreezeContract", withdraw)
        }
    };
    let mut any = Vec::new();
    wire_bytes(&mut any, 1, contract.1.as_bytes());
    wire_bytes(&mut any, 2, &contract.2);
    let mut encoded_contract = Vec::new();
    wire_varint(&mut encoded_contract, 1, contract.0);
    wire_bytes(&mut encoded_contract, 2, &any);

    wire_bytes(&mut output, 1, &fields.ref_block_bytes);
    wire_bytes(&mut output, 4, &fields.ref_block_hash);
    wire_varint(&mut output, 8, fields.expiration);
    if let Some(data) = fields.data {
        wire_bytes(&mut output, 10, &data);
    }
    wire_bytes(&mut output, 11, &encoded_contract);
    wire_varint(&mut output, 14, fields.timestamp);
    if let Some(fee_limit) = fields.fee_limit {
        wire_varint(&mut output, 18, fee_limit);
    }
    Ok(output)
}

/// `FreezeBalanceV2Contract`/`UnfreezeBalanceV2Contract`: proto3 omits a
/// zero amount and the default `BANDWIDTH` resource.
fn stake_contract(owner_address: &[u8], balance: u64, resource: hw::TronResource) -> Vec<u8> {
    let mut contract = Vec::new();
    wire_bytes(&mut contract, 1, owner_address);
    if balance > 0 {
        wire_varint(&mut contract, 2, balance);
    }
    if resource == hw::TronResource::Energy {
        wire_varint(&mut contract, 3, 1);
    }
    contract
}

fn wire_bytes(output: &mut Vec<u8>, field: u64, value: &[u8]) {
    encode_varint(output, field << 3 | 2);
    encode_varint(output, value.len() as u64);
    output.extend_from_slice(value);
}

fn wire_varint(output: &mut Vec<u8>, field: u64, value: u64) {
    encode_varint(output, field << 3);
    encode_varint(output, value);
}

fn encode_varint(output: &mut Vec<u8>, value: u64) {
    let mut value = value;
    while value >= 0x80 {
        output.push((value as u8 & 0x7f) | 0x80);
        value >>= 7;
    }
    output.push(value as u8);
}

/// Packs a hardware-returned Ethereum signature into the 65-byte
/// `r ‖ s ‖ v` shape `EthereumSignerFfi::sign_digest` produces for the
/// software path, folding `v` down to a single byte (legacy 27/28 —
/// `ethereum_sign_message`/`ethereum_sign_typed_data` never EIP-155-fold
/// it the way transaction signing does).
fn encode_message_signature(signature: hw::EthereumSignature) -> Result<Vec<u8>, WalletKitErrorFfi> {
    let r: [u8; 32] = signature.r.as_slice().try_into().map_err(|_| WalletKitErrorFfi::SigningFailed {
        reason: format!("expected a 32-byte r, got {} bytes", signature.r.len()),
    })?;
    let s: [u8; 32] = signature.s.as_slice().try_into().map_err(|_| WalletKitErrorFfi::SigningFailed {
        reason: format!("expected a 32-byte s, got {} bytes", signature.s.len()),
    })?;
    let v: u8 = signature.v.try_into().map_err(|_| WalletKitErrorFfi::SigningFailed {
        reason: format!("expected a legacy 27/28 v, got {}", signature.v),
    })?;

    let mut out = Vec::with_capacity(65);
    out.extend_from_slice(&r);
    out.extend_from_slice(&s);
    out.push(v);
    Ok(out)
}

/// `BigIntFfi::magnitude_be_bytes` is already the minimal big-endian
/// encoding the device's wire protocol expects; every field is
/// non-negative by construction (decoded from unsigned RLP `U256`s),
/// so this only guards against a value that shouldn't be able to occur.
fn nonnegative_be_bytes(value: &BigIntFfi) -> Result<Vec<u8>, WalletKitErrorFfi> {
    if value.negative {
        return Err(WalletKitErrorFfi::SigningFailed {
            reason: "expected a non-negative integer for a hardware-signed Ethereum field".to_string(),
        });
    }
    Ok(value.magnitude_be_bytes.clone())
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::common::Segment;

    #[test]
    fn to_hardware_curve_maps_every_curve() {
        assert_eq!(to_hardware_curve(CurveFfi::Secp256k1), hw::HardwareCurve::Secp256k1);
        assert_eq!(to_hardware_curve(CurveFfi::Ed25519), hw::HardwareCurve::Ed25519);
    }

    #[test]
    fn to_hardware_bitcoin_network_maps_every_network() {
        assert_eq!(to_hardware_bitcoin_network(BitcoinNetworkFfi::Mainnet), hw::HardwareBitcoinNetwork::Mainnet);
        assert_eq!(to_hardware_bitcoin_network(BitcoinNetworkFfi::Testnet), hw::HardwareBitcoinNetwork::Testnet);
        assert_eq!(to_hardware_bitcoin_network(BitcoinNetworkFfi::Signet), hw::HardwareBitcoinNetwork::Signet);
        assert_eq!(to_hardware_bitcoin_network(BitcoinNetworkFfi::Regtest), hw::HardwareBitcoinNetwork::Regtest);
    }

    #[test]
    fn to_hardware_segments_preserves_index_and_hardened_flags() {
        let path = DerivationPathFfi {
            segments: vec![Segment { index: 44, hardened: true }, Segment { index: 0, hardened: false }],
        };
        let segments = to_hardware_segments(&path);
        assert_eq!(segments, vec![
            hw::HardwarePathSegment { index: 44, hardened: true },
            hw::HardwarePathSegment { index: 0, hardened: false },
        ]);
    }

    #[test]
    fn nonnegative_be_bytes_passes_through_the_magnitude() {
        let value = BigIntFfi::from(42u64);
        assert_eq!(nonnegative_be_bytes(&value).unwrap(), value.magnitude_be_bytes);
    }

    #[test]
    fn nonnegative_be_bytes_rejects_a_negative_value() {
        let negative = BigIntFfi { magnitude_be_bytes: vec![1], negative: true };
        assert!(matches!(nonnegative_be_bytes(&negative), Err(WalletKitErrorFfi::SigningFailed { .. })));
    }

    #[test]
    fn to_ethereum_tx_fields_converts_every_field() {
        let tx = EthereumSignTxFfi {
            nonce: BigIntFfi::from(1u64),
            gas_price: BigIntFfi::from(2u64),
            gas_limit: BigIntFfi::from(3u64),
            to: Some(vec![0xab; 20]),
            value: BigIntFfi::from(4u64),
            data: vec![0xde, 0xad],
            chain_id: 11_155_111,
        };
        let fields = to_ethereum_tx_fields(tx).unwrap();
        assert_eq!(fields.nonce, vec![1]);
        assert_eq!(fields.gas_price, vec![2]);
        assert_eq!(fields.gas_limit, vec![3]);
        assert_eq!(fields.to, Some(vec![0xab; 20]));
        assert_eq!(fields.value, vec![4]);
        assert_eq!(fields.data, vec![0xde, 0xad]);
        assert_eq!(fields.chain_id, 11_155_111);
    }

    #[test]
    fn to_ethereum_eip1559_tx_fields_converts_every_field() {
        let tx = EthereumEIP1559SignTxFfi {
            nonce: BigIntFfi::from(1u64),
            max_priority_fee_per_gas: BigIntFfi::from(2u64),
            max_fee_per_gas: BigIntFfi::from(3u64),
            gas_limit: BigIntFfi::from(4u64),
            to: Some(vec![0xab; 20]),
            value: BigIntFfi::from(5u64),
            data: vec![0xde, 0xad],
            chain_id: 11_155_111,
        };
        let fields = to_ethereum_eip1559_tx_fields(tx).unwrap();
        assert_eq!(fields.nonce, vec![1]);
        assert_eq!(fields.max_priority_fee_per_gas, vec![2]);
        assert_eq!(fields.max_fee_per_gas, vec![3]);
        assert_eq!(fields.gas_limit, vec![4]);
        assert_eq!(fields.to, Some(vec![0xab; 20]));
        assert_eq!(fields.value, vec![5]);
        assert_eq!(fields.data, vec![0xde, 0xad]);
        assert_eq!(fields.chain_id, 11_155_111);
    }

    #[test]
    fn to_tron_tx_fields_parses_a_native_transfer() {
        let transaction = r#"{
            "raw_data": {
                "ref_block_bytes": "e942",
                "ref_block_hash": "6394747da9fee421",
                "expiration": 1752562632000,
                "timestamp": 1752562572000,
                "contract": [{
                    "type": "TransferContract",
                    "parameter": { "value": {
                        "owner_address": "41f2cd810c48c401d392ead3c6e1e1cb9f57750a58",
                        "to_address": "4141f82674a30ae1328745d08afe2d1a0a24195283",
                        "amount": 18123456
                    }}
                }]
            }
        }"#;
        let fields = to_tron_tx_fields(transaction).unwrap();
        assert_eq!(fields.ref_block_bytes, vec![0xe9, 0x42]);
        assert_eq!(fields.ref_block_hash, hex::decode("6394747da9fee421").unwrap());
        assert!(matches!(fields.contract, hw::TronContract::Transfer { amount: 18_123_456, .. }));
    }

    /// `raw_data_hex` from TronWeb 6.5.1 for a TRC-20 call carrying
    /// `call_value` and a memo — the dapp-browser case Trezor must reproduce.
    #[test]
    fn tron_raw_data_reproduces_a_call_with_call_value_and_memo() {
        let transaction = r#"{
            "raw_data": {
                "ref_block_bytes": "e942",
                "ref_block_hash": "6394747da9fee421",
                "expiration": 1752562632000,
                "timestamp": 1752562572000,
                "fee_limit": 150000000,
                "data": "6d656d6f",
                "contract": [{
                    "type": "TriggerSmartContract",
                    "parameter": { "value": {
                        "owner_address": "417e5f4552091a69125d5dfcb7b8c2659029395bdf",
                        "contract_address": "41a614f803b6fd780986a42c78ec9c7f77e6ded13c",
                        "call_value": 5000000,
                        "data": "a9059cbb000000000000000000000000a614f803b6fd780986a42c78ec9c7f77e6ded13c00000000000000000000000000000000000000000000000000000000000f4240"
                    }}
                }]
            }
        }"#;
        let expected = "0a02e94222086394747da9fee42140c08afee6803352046d656d6f5ab301081f12ae010a31747970652e676f6f676c65617069732e636f6d2f70726f746f636f6c2e54726967676572536d617274436f6e747261637412790a15417e5f4552091a69125d5dfcb7b8c2659029395bdf121541a614f803b6fd780986a42c78ec9c7f77e6ded13c18c096b1022244a9059cbb000000000000000000000000a614f803b6fd780986a42c78ec9c7f77e6ded13c00000000000000000000000000000000000000000000000000000000000f424070e0b5fae68033900180a3c347";
        assert_eq!(hex::encode(tron_raw_data(transaction.to_string()).unwrap()), expected);
    }

    fn stake_transaction(contract_type: &str, value: &str) -> String {
        format!(r#"{{
            "raw_data": {{
                "ref_block_bytes": "e942", "ref_block_hash": "6394747da9fee421",
                "expiration": 1752562632000, "timestamp": 1752562572000,
                "contract": [{{ "type": "{contract_type}", "parameter": {{ "value": {value} }} }}]
            }}
        }}"#)
    }

    /// `raw_data_hex` from TronWeb 6.5.1 for each Stake 2.0 contract, as
    /// `TronRawTransactionTests` in Swift uses.
    #[test]
    fn tron_raw_data_reproduces_stake_2_contracts() {
        let owner = r#""owner_address": "417e5f4552091a69125d5dfcb7b8c2659029395bdf""#;
        let cases = [
            (
                stake_transaction("FreezeBalanceV2Contract", &format!(r#"{{ {owner}, "frozen_balance": 100000000, "resource": "ENERGY" }}"#)),
                "0a02e94222086394747da9fee42140c08afee680335a5a083612560a34747970652e676f6f676c65617069732e636f6d2f70726f746f636f6c2e467265657a6542616c616e63655632436f6e7472616374121e0a15417e5f4552091a69125d5dfcb7b8c2659029395bdf1080c2d72f180170e0b5fae68033",
            ),
            (
                stake_transaction("FreezeBalanceV2Contract", &format!(r#"{{ {owner}, "frozen_balance": 25000000 }}"#)),
                "0a02e94222086394747da9fee42140c08afee680335a58083612540a34747970652e676f6f676c65617069732e636f6d2f70726f746f636f6c2e467265657a6542616c616e63655632436f6e7472616374121c0a15417e5f4552091a69125d5dfcb7b8c2659029395bdf10c0f0f50b70e0b5fae68033",
            ),
            (
                stake_transaction("UnfreezeBalanceV2Contract", &format!(r#"{{ {owner}, "unfreeze_balance": 40000000, "resource": "ENERGY" }}"#)),
                "0a02e94222086394747da9fee42140c08afee680335a5c083712580a36747970652e676f6f676c65617069732e636f6d2f70726f746f636f6c2e556e667265657a6542616c616e63655632436f6e7472616374121e0a15417e5f4552091a69125d5dfcb7b8c2659029395bdf1080b48913180170e0b5fae68033",
            ),
            (
                stake_transaction("WithdrawExpireUnfreezeContract", &format!("{{ {owner} }}")),
                "0a02e94222086394747da9fee42140c08afee680335a5a083812560a3b747970652e676f6f676c65617069732e636f6d2f70726f746f636f6c2e5769746864726177457870697265556e667265657a65436f6e747261637412170a15417e5f4552091a69125d5dfcb7b8c2659029395bdf70e0b5fae68033",
            ),
        ];
        for (transaction, expected) in cases {
            assert_eq!(hex::encode(tron_raw_data(transaction).unwrap()), expected);
        }
    }

    #[test]
    fn to_tron_tx_fields_parses_a_bandwidth_freeze_without_a_resource() {
        let transaction = stake_transaction("FreezeBalanceV2Contract", r#"{ "owner_address": "41", "frozen_balance": 7 }"#);
        assert!(matches!(
            to_tron_tx_fields(&transaction).unwrap().contract,
            hw::TronContract::FreezeBalanceV2 { balance: 7, resource: hw::TronResource::Bandwidth, .. }
        ));
    }

    #[test]
    fn to_tron_tx_fields_rejects_tron_power() {
        let transaction = stake_transaction(
            "FreezeBalanceV2Contract",
            r#"{ "owner_address": "41", "frozen_balance": 7, "resource": "TRON_POWER" }"#,
        );
        assert!(matches!(to_tron_tx_fields(&transaction), Err(WalletKitErrorFfi::UnsupportedDevice { .. })));
    }

    #[test]
    fn to_tron_tx_fields_rejects_a_non_integer_call_value() {
        let transaction = r#"{
            "raw_data": {
                "ref_block_bytes": "e942", "ref_block_hash": "6394747da9fee421",
                "expiration": 1, "timestamp": 1,
                "contract": [{ "type": "TriggerSmartContract", "parameter": { "value": {
                    "owner_address": "41", "contract_address": "41", "call_value": "5", "data": ""
                }}}]
            }
        }"#;
        assert!(matches!(to_tron_tx_fields(transaction), Err(WalletKitErrorFfi::SigningFailed { .. })));
    }

    #[test]
    fn to_solana_tx_fields_decodes_the_message_and_token_accounts() {
        let transaction = r#"{
            "message": "AQID",
            "tokenAccounts": [{
                "baseAddress": "owner",
                "tokenProgram": "program",
                "tokenMint": "mint",
                "tokenAccount": "account"
            }]
        }"#;
        let fields = to_solana_tx_fields(transaction).unwrap();
        assert_eq!(fields.serialized_message, vec![1, 2, 3]);
        assert_eq!(fields.token_accounts.len(), 1);
        assert_eq!(fields.token_accounts[0].base_address, "owner");
        assert_eq!(fields.token_accounts[0].token_mint, "mint");
    }

    #[test]
    fn to_solana_tx_fields_defaults_to_no_token_accounts() {
        let fields = to_solana_tx_fields(r#"{"message": "AQID"}"#).unwrap();
        assert!(fields.token_accounts.is_empty());
    }

    #[test]
    fn to_solana_tx_fields_rejects_invalid_base64() {
        assert!(matches!(
            to_solana_tx_fields(r#"{"message": "not-base64!"}"#),
            Err(WalletKitErrorFfi::SigningFailed { .. })
        ));
    }

    #[test]
    fn encode_message_signature_packs_r_s_v_into_65_bytes() {
        let signature = hw::EthereumSignature { v: 27, r: vec![0xaa; 32], s: vec![0xbb; 32] };
        let encoded = encode_message_signature(signature).unwrap();
        assert_eq!(encoded.len(), 65);
        assert_eq!(&encoded[0..32], [0xaa; 32]);
        assert_eq!(&encoded[32..64], [0xbb; 32]);
        assert_eq!(encoded[64], 27);
    }

    #[test]
    fn encode_message_signature_rejects_an_eip_155_folded_v() {
        let signature = hw::EthereumSignature { v: 11_155_111 * 2 + 35, r: vec![0u8; 32], s: vec![0u8; 32] };
        assert!(matches!(encode_message_signature(signature), Err(WalletKitErrorFfi::SigningFailed { .. })));
    }

    #[test]
    fn encode_message_signature_rejects_a_short_r() {
        let signature = hw::EthereumSignature { v: 27, r: vec![1, 2, 3], s: vec![0u8; 32] };
        assert!(matches!(encode_message_signature(signature), Err(WalletKitErrorFfi::SigningFailed { .. })));
    }
}
