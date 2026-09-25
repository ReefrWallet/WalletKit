use std::sync::Arc;

use walletkit_hardware as hw;

use crate::{
    blockchain_clients::{
        BitcoinNetworkFfi, EthereumEIP1559SignTxFfi, EthereumEIP1559SignatureFfi, EthereumSignTxFfi,
        EthereumSignatureFfi,
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

    /// Signs the raw TronGrid transaction response on the device. WalletKit
    /// currently constructs `TransferContract` and `TriggerSmartContract`.
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
            data: address(payload, "data")?,
        },
        _ => return Err(WalletKitErrorFfi::UnsupportedDevice { reason: "Trezor Tron signing supports only transfer and smart-contract calls".to_string() }),
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
        hw::TronContract::TriggerSmartContract { owner_address, contract_address, data } => {
            let mut trigger = Vec::new();
            wire_bytes(&mut trigger, 1, &owner_address);
            wire_bytes(&mut trigger, 2, &contract_address);
            wire_bytes(&mut trigger, 4, &data);
            (31, "type.googleapis.com/protocol.TriggerSmartContract", trigger)
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
}
