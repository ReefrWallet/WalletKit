//! CBOR codecs for the CIP-30 read APIs: `Value`, `TransactionUnspentOutput`,
//! addresses, script references, and value-target UTxO selection.

use std::collections::BTreeMap;

use cardano_serialization_lib::{
    Address, BigNum, Ed25519KeyHash, NativeScript, NativeScripts, PlutusData, PlutusScript, ScriptAll, ScriptAny,
    ScriptNOfK, ScriptPubkey, ScriptRef, TimelockExpiry, TimelockStart, TransactionHash, TransactionInput,
    TransactionOutput, TransactionUnspentOutput, Value,
};

use crate::blockchain_clients::cardano::{
    invalid_address, multiasset, signing_failed, value_assets, CardanoAssetFfi, CardanoUtxoFfi,
};
use crate::errors::WalletKitErrorFfi;

#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct CardanoValueFfi {
    pub assets: Vec<CardanoAssetFfi>,
    pub lovelace: String,
}

/// A UTxO with everything CIP-30 returns: datum and reference script included.
#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct CardanoDappUtxoFfi {
    pub address: String,
    pub assets: Vec<CardanoAssetFfi>,
    pub datum_hash: Option<Vec<u8>>,
    /// `PlutusData` CBOR of an inline datum.
    pub inline_datum: Option<Vec<u8>>,
    pub lovelace: String,
    pub output_index: u32,
    /// `ScriptRef` CBOR (see `cardano_script_ref_*`).
    pub script_ref: Option<Vec<u8>>,
    pub tx_hash: Vec<u8>,
}

fn to_value(value: &CardanoValueFfi) -> Result<Value, WalletKitErrorFfi> {
    let mut result = Value::new(&cardano_serialization_lib::BigNum::from_str(&value.lovelace).map_err(signing_failed)?);
    if !value.assets.is_empty() {
        result.set_multiasset(&multiasset(value.assets.clone())?);
    }

    Ok(result)
}

fn from_value(value: &Value) -> CardanoValueFfi {
    CardanoValueFfi {
        assets: value_assets(value),
        lovelace: value.coin().to_str(),
    }
}

fn parse_address(address: &str) -> Result<Address, WalletKitErrorFfi> {
    match Address::from_bech32(address) {
        Ok(address) => Ok(address),
        Err(_) => hex::decode(address)
            .map_err(invalid_address)
            .and_then(|bytes| Address::from_bytes(bytes).map_err(invalid_address)),
    }
}

fn to_unspent_output(utxo: &CardanoDappUtxoFfi) -> Result<TransactionUnspentOutput, WalletKitErrorFfi> {
    let tx_hash = TransactionHash::from_bytes(utxo.tx_hash.clone()).map_err(signing_failed)?;
    let input = TransactionInput::new(&tx_hash, utxo.output_index);
    let value = to_value(&CardanoValueFfi {
        assets: utxo.assets.clone(),
        lovelace: utxo.lovelace.clone(),
    })?;
    let mut output = TransactionOutput::new(&parse_address(&utxo.address)?, &value);

    if let Some(hash) = &utxo.datum_hash {
        output.set_data_hash(&cardano_serialization_lib::DataHash::from_bytes(hash.clone()).map_err(signing_failed)?);
    }
    if let Some(datum) = &utxo.inline_datum {
        output.set_plutus_data(&PlutusData::from_bytes(datum.clone()).map_err(signing_failed)?);
    }
    if let Some(script) = &utxo.script_ref {
        output.set_script_ref(&ScriptRef::from_bytes(script.clone()).map_err(signing_failed)?);
    }

    Ok(TransactionUnspentOutput::new(&input, &output))
}

/// CBOR hex of a `Value`: a bare coin, or `[coin, multiasset]`.
#[uniffi::export]
pub fn cardano_value_to_hex(value: CardanoValueFfi) -> Result<String, WalletKitErrorFfi> {
    Ok(to_value(&value)?.to_hex())
}

#[uniffi::export]
pub fn cardano_value_from_hex(hex: String) -> Result<CardanoValueFfi, WalletKitErrorFfi> {
    Ok(from_value(&Value::from_hex(&hex).map_err(signing_failed)?))
}

/// CBOR hex of a `TransactionUnspentOutput` (`[input, output]`).
#[uniffi::export]
pub fn cardano_utxo_to_hex(utxo: CardanoDappUtxoFfi) -> Result<String, WalletKitErrorFfi> {
    Ok(to_unspent_output(&utxo)?.to_hex())
}

#[uniffi::export]
pub fn cardano_utxo_from_hex(hex: String) -> Result<CardanoDappUtxoFfi, WalletKitErrorFfi> {
    let unspent = TransactionUnspentOutput::from_hex(&hex).map_err(signing_failed)?;
    let input = unspent.input();
    let output = unspent.output();
    let amount = output.amount();

    Ok(CardanoDappUtxoFfi {
        address: output
            .address()
            .to_bech32(None)
            .unwrap_or_else(|_| hex::encode(output.address().to_bytes())),
        assets: value_assets(&amount),
        datum_hash: output.data_hash().map(|hash| hash.to_bytes()),
        inline_datum: output.plutus_data().map(|data| data.to_bytes()),
        lovelace: amount.coin().to_str(),
        output_index: input.index(),
        script_ref: output.script_ref().map(|script| script.to_bytes()),
        tx_hash: input.transaction_id().to_bytes(),
    })
}

/// Raw address bytes of a bech32 (or hex) address.
#[uniffi::export]
pub fn cardano_address_to_bytes(address: String) -> Result<Vec<u8>, WalletKitErrorFfi> {
    Ok(parse_address(&address)?.to_bytes())
}

/// Bech32 form of raw address bytes (hex for Byron, which has none).
#[uniffi::export]
pub fn cardano_address_from_bytes(bytes: Vec<u8>) -> Result<String, WalletKitErrorFfi> {
    let address = Address::from_bytes(bytes.clone()).map_err(invalid_address)?;

    Ok(address.to_bech32(None).unwrap_or_else(|_| hex::encode(bytes)))
}

/// `ScriptRef` CBOR for a Plutus script (`version` 1, 2 or 3) given its
/// plain (single-wrapped) script CBOR.
#[uniffi::export]
pub fn cardano_script_ref_plutus(version: u8, script: Vec<u8>) -> Result<Vec<u8>, WalletKitErrorFfi> {
    let script = match version {
        1 => PlutusScript::from_bytes(script).map_err(signing_failed),
        2 => PlutusScript::from_bytes_v2(script).map_err(signing_failed),
        3 => PlutusScript::from_bytes_v3(script).map_err(signing_failed),
        _ => Err(signing_failed("Unsupported Plutus language version")),
    }?;

    Ok(ScriptRef::new_plutus_script(&script).to_bytes())
}

fn native_script_from_json_value(value: &serde_json::Value) -> Result<NativeScript, WalletKitErrorFfi> {
    let invalid = |what: &str| signing_failed(format!("Invalid Cardano native script: {what}"));
    let children = |value: &serde_json::Value| -> Result<NativeScripts, WalletKitErrorFfi> {
        let mut scripts = NativeScripts::new();
        for child in value["scripts"].as_array().ok_or_else(|| invalid("scripts"))? {
            scripts.add(&native_script_from_json_value(child)?);
        }
        Ok(scripts)
    };
    let slot = |value: &serde_json::Value| -> Result<BigNum, WalletKitErrorFfi> {
        BigNum::from_str(&value["slot"].as_u64().ok_or_else(|| invalid("slot"))?.to_string()).map_err(signing_failed)
    };

    match value["type"].as_str() {
        Some("sig") => {
            let hash = hex::decode(value["keyHash"].as_str().ok_or_else(|| invalid("keyHash"))?)
                .map_err(|_| invalid("keyHash"))?;
            Ok(NativeScript::new_script_pubkey(&ScriptPubkey::new(
                &Ed25519KeyHash::from_bytes(hash).map_err(|_| invalid("keyHash"))?,
            )))
        }
        Some("all") => Ok(NativeScript::new_script_all(&ScriptAll::new(&children(value)?))),
        Some("any") => Ok(NativeScript::new_script_any(&ScriptAny::new(&children(value)?))),
        Some("atLeast") => {
            let required = value["required"].as_u64().ok_or_else(|| invalid("required"))?;
            Ok(NativeScript::new_script_n_of_k(&ScriptNOfK::new(
                u32::try_from(required).map_err(|_| invalid("required"))?,
                &children(value)?,
            )))
        }
        Some("after") => Ok(NativeScript::new_timelock_start(&TimelockStart::new_timelockstart(&slot(value)?))),
        Some("before") => Ok(NativeScript::new_timelock_expiry(&TimelockExpiry::new_timelockexpiry(&slot(value)?))),
        _ => Err(invalid("type")),
    }
}

/// Native script CBOR from the cardano-cli JSON that Blockfrost's
/// `scripts/{hash}/json` returns (`sig`, `all`, `any`, `atLeast`, `after`, `before`).
#[uniffi::export]
pub fn cardano_native_script_from_json(json: String) -> Result<Vec<u8>, WalletKitErrorFfi> {
    let value: serde_json::Value = serde_json::from_str(&json).map_err(signing_failed)?;

    Ok(native_script_from_json_value(&value)?.to_bytes())
}

/// `ScriptRef` CBOR for a native script given its CBOR.
#[uniffi::export]
pub fn cardano_script_ref_native(script: Vec<u8>) -> Result<Vec<u8>, WalletKitErrorFfi> {
    let script = NativeScript::from_bytes(script).map_err(signing_failed)?;

    Ok(ScriptRef::new_native_script(&script).to_bytes())
}

/// Picks UTxOs covering `target`: for each asset, largest quantity first,
/// then largest lovelace until the coin target is covered. Returns indexes
/// into `utxos`, or `None` if the target is unreachable.
#[uniffi::export]
pub fn cardano_select_utxos(target: CardanoValueFfi, utxos: Vec<CardanoUtxoFfi>) -> Result<Option<Vec<u32>>, WalletKitErrorFfi> {
    type Unit = (Vec<u8>, Vec<u8>);

    let parse = |text: &str| text.parse::<u128>().map_err(signing_failed);
    let mut needed: BTreeMap<Unit, u128> = BTreeMap::new();
    for asset in &target.assets {
        *needed.entry((asset.policy_id.clone(), asset.name.clone())).or_default() += parse(&asset.quantity)?;
    }
    let mut coin_needed = parse(&target.lovelace)?;

    let mut held: Vec<(BTreeMap<Unit, u128>, u128)> = vec![];
    for utxo in &utxos {
        let mut assets: BTreeMap<Unit, u128> = BTreeMap::new();
        for asset in &utxo.assets {
            *assets.entry((asset.policy_id.clone(), asset.name.clone())).or_default() += parse(&asset.quantity)?;
        }
        held.push((assets, parse(&utxo.lovelace)?));
    }

    let mut chosen: Vec<usize> = vec![];
    for (unit, mut remaining) in needed {
        let mut candidates: Vec<usize> = (0..held.len())
            .filter(|index| held[*index].0.contains_key(&unit))
            .collect();
        candidates.sort_by_key(|index| std::cmp::Reverse(held[*index].0[&unit]));
        // Already-chosen UTxOs count first so they aren't wasted.
        for index in chosen.iter().copied() {
            remaining = remaining.saturating_sub(held[index].0.get(&unit).copied().unwrap_or(0));
        }
        for index in candidates {
            if remaining == 0 {
                break;
            }
            if chosen.contains(&index) {
                continue;
            }
            remaining = remaining.saturating_sub(held[index].0[&unit]);
            chosen.push(index);
        }
        if remaining > 0 {
            return Ok(None);
        }
    }

    for index in &chosen {
        coin_needed = coin_needed.saturating_sub(held[*index].1);
    }
    let mut rest: Vec<usize> = (0..held.len()).filter(|index| !chosen.contains(index)).collect();
    rest.sort_by_key(|index| std::cmp::Reverse(held[*index].1));
    for index in rest {
        if coin_needed == 0 {
            break;
        }
        coin_needed = coin_needed.saturating_sub(held[index].1);
        chosen.push(index);
    }
    if coin_needed > 0 {
        return Ok(None);
    }

    chosen.sort_unstable();
    Ok(Some(chosen.into_iter().map(|index| index as u32).collect()))
}
