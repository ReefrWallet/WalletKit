//! Which of the account's keys a dapp transaction needs, and what is still
//! missing, from the account's public key alone (no entropy).
//!
//! The ownership model is normative in the CIP-30 plan: required key hashes
//! come from inputs, collateral, `required_signers`, withdrawals,
//! certificates and the native scripts those credentials reference. A
//! pre-existing vkey witness only counts if its signature verifies over the
//! original body hash.

use std::collections::{BTreeMap, BTreeSet, HashMap, HashSet};

use cardano_serialization_lib::{Address, Bip32PublicKey, Credential, NativeScript, NativeScriptKind, ScriptHash};

use super::decode::{certificate_requirement, parse_transaction, CertificateRequirement};
use crate::blockchain_clients::cardano::{invalid_address, normalize_account_xpub, signing_failed, CardanoSigningPathFfi};
use crate::errors::WalletKitErrorFfi;

/// Keys scanned past the highest used index (BIP-44 style gap limit).
const GAP_LIMIT: u32 = 20;
const STAKE_ROLE: u32 = 2;

#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct CardanoUsedIndicesFfi {
    pub max_used_index: Option<u32>,
    pub role: u32,
}

/// An output a requirement can be resolved against: one of the account's
/// UTxOs, or a reference input fetched from the chain.
#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct CardanoResolvedOutputFfi {
    pub address: String,
    pub output_index: u32,
    pub script_hash: Option<Vec<u8>>,
    pub tx_hash: Vec<u8>,
}

/// A script body obtained by hash. `native_script` is its CBOR when native;
/// `None` means a Plutus script, which needs no key witness from us.
#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct CardanoResolvedScriptFfi {
    pub hash: Vec<u8>,
    pub native_script: Option<Vec<u8>>,
}

#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct CardanoSignersFfi {
    /// Required key hashes with no owned key and no valid witness.
    pub missing: Vec<Vec<u8>>,
    /// Required key hashes already covered by a valid existing witness.
    pub satisfied: Vec<Vec<u8>>,
    /// Owned keys that must sign, excluding already-valid witnesses.
    pub to_sign: Vec<CardanoSigningPathFfi>,
    /// Requirements that couldn't be resolved to a credential or script.
    pub unresolved: Vec<String>,
    pub valid_existing_count: u32,
}

struct Context {
    owned: HashMap<Vec<u8>, (u32, u32)>,
    start: Option<u64>,
    ttl: Option<u64>,
    valid: HashSet<Vec<u8>>,
}

enum Requirement {
    Key(Vec<u8>),
    Script(Vec<u8>),
}

fn owned_keys(account_xpub: &str, used: &[CardanoUsedIndicesFfi]) -> Result<HashMap<Vec<u8>, (u32, u32)>, WalletKitErrorFfi> {
    let account = Bip32PublicKey::from_bech32(&normalize_account_xpub(account_xpub)?).map_err(invalid_address)?;
    let mut owned = HashMap::new();

    for role in 0..=1 {
        let max = used
            .iter()
            .filter(|entry| entry.role == role)
            .filter_map(|entry| entry.max_used_index)
            .max();
        let role_key = account.derive(role).map_err(invalid_address)?;
        for index in 0..=max.map_or(0, |max| max + 1) + GAP_LIMIT {
            let key = role_key.derive(index).map_err(invalid_address)?.to_raw_key();
            owned.insert(key.hash().to_bytes(), (role, index));
        }
    }

    let stake = account
        .derive(STAKE_ROLE)
        .map_err(invalid_address)?
        .derive(0)
        .map_err(invalid_address)?
        .to_raw_key();
    owned.insert(stake.hash().to_bytes(), (STAKE_ROLE, 0));

    Ok(owned)
}

fn requirement(credential: &Credential) -> Option<Requirement> {
    match (credential.to_keyhash(), credential.to_scripthash()) {
        (Some(hash), _) => Some(Requirement::Key(hash.to_bytes())),
        (_, Some(hash)) => Some(Requirement::Script(hash.to_bytes())),
        _ => None,
    }
}

fn address_requirement(address: &str) -> Option<Requirement> {
    let address = Address::from_bech32(address)
        .ok()
        .or_else(|| hex::decode(address).ok().and_then(|bytes| Address::from_bytes(bytes).ok()))?;

    requirement(&address.payment_cred()?)
}

fn slot(value: &str) -> Option<u64> {
    value.parse().ok()
}

/// Returns the owned keys needed to satisfy `script`, or `Err` if it can't
/// be satisfied. Valid existing witnesses satisfy a leaf for free.
fn evaluate(script: &NativeScript, context: &Context) -> Result<BTreeSet<Vec<u8>>, ()> {
    match script.kind() {
        NativeScriptKind::ScriptPubkey => {
            let hash = script.as_script_pubkey().ok_or(())?.addr_keyhash().to_bytes();
            if context.valid.contains(&hash) {
                Ok(BTreeSet::new())
            } else if context.owned.contains_key(&hash) {
                Ok(BTreeSet::from([hash]))
            } else {
                Err(())
            }
        }
        NativeScriptKind::ScriptAll => {
            let children = script.as_script_all().ok_or(())?.native_scripts();
            let mut keys = BTreeSet::new();
            for index in 0..children.len() {
                keys.extend(evaluate(&children.get(index), context)?);
            }
            Ok(keys)
        }
        NativeScriptKind::ScriptAny => {
            let children = script.as_script_any().ok_or(())?.native_scripts();
            (0..children.len())
                .filter_map(|index| evaluate(&children.get(index), context).ok())
                .min_by_key(BTreeSet::len)
                .ok_or(())
        }
        NativeScriptKind::ScriptNOfK => {
            let node = script.as_script_n_of_k().ok_or(())?;
            let children = node.native_scripts();
            let mut satisfied: Vec<_> = (0..children.len())
                .filter_map(|index| evaluate(&children.get(index), context).ok())
                .collect();
            let needed = node.n() as usize;
            if satisfied.len() < needed {
                return Err(());
            }
            satisfied.sort_by_key(BTreeSet::len);
            Ok(satisfied.into_iter().take(needed).flatten().collect())
        }
        NativeScriptKind::TimelockStart => {
            let from = slot(&script.as_timelock_start().ok_or(())?.slot_bignum().to_str()).ok_or(())?;
            context.start.filter(|start| *start >= from).map(|_| BTreeSet::new()).ok_or(())
        }
        NativeScriptKind::TimelockExpiry => {
            let until = slot(&script.as_timelock_expiry().ok_or(())?.slot_bignum().to_str()).ok_or(())?;
            context.ttl.filter(|ttl| *ttl <= until).map(|_| BTreeSet::new()).ok_or(())
        }
    }
}

/// Foreign key hashes of a script the account can't satisfy: every pubkey
/// leaf with neither an owned key nor a valid witness.
fn missing_leaves(script: &NativeScript, context: &Context, missing: &mut BTreeSet<Vec<u8>>) {
    let children = match script.kind() {
        NativeScriptKind::ScriptPubkey => {
            if let Some(node) = script.as_script_pubkey() {
                let hash = node.addr_keyhash().to_bytes();
                if !context.valid.contains(&hash) && !context.owned.contains_key(&hash) {
                    missing.insert(hash);
                }
            }
            return;
        }
        NativeScriptKind::ScriptAll => script.as_script_all().map(|node| node.native_scripts()),
        NativeScriptKind::ScriptAny => script.as_script_any().map(|node| node.native_scripts()),
        NativeScriptKind::ScriptNOfK => script.as_script_n_of_k().map(|node| node.native_scripts()),
        NativeScriptKind::TimelockStart | NativeScriptKind::TimelockExpiry => None,
    };
    let Some(children) = children else {
        return;
    };
    for index in 0..children.len() {
        missing_leaves(&children.get(index), context, missing);
    }
}

fn native_script(bytes: &[u8]) -> Result<NativeScript, WalletKitErrorFfi> {
    NativeScript::from_bytes(bytes.to_vec()).map_err(signing_failed)
}

fn path(role_index: (u32, u32)) -> CardanoSigningPathFfi {
    CardanoSigningPathFfi {
        index: role_index.1,
        role: role_index.0,
    }
}

/// Resolves what `transaction` needs from the account, per the plan's
/// ownership model. `owned_outputs` are the account's UTxOs (spent inputs
/// resolve against them); `reference_outputs` and `scripts` are what the
/// caller fetched for the transaction's reference inputs and script hashes.
#[uniffi::export]
pub fn cardano_required_signers(
    transaction: Vec<u8>,
    account_xpub: String,
    owned_outputs: Vec<CardanoResolvedOutputFfi>,
    reference_outputs: Vec<CardanoResolvedOutputFfi>,
    scripts: Vec<CardanoResolvedScriptFfi>,
    used_indices: Vec<CardanoUsedIndicesFfi>,
) -> Result<CardanoSignersFfi, WalletKitErrorFfi> {
    let fixed = parse_transaction(&transaction)?;
    let body = fixed.body();
    let witnesses = fixed.witness_set();
    let body_hash = fixed.transaction_hash().to_bytes();

    let mut valid = HashSet::new();
    if let Some(vkeys) = witnesses.vkeys() {
        for index in 0..vkeys.len() {
            let witness = vkeys.get(index);
            let key = witness.vkey().public_key();
            if key.verify(&body_hash, &witness.signature()) {
                valid.insert(key.hash().to_bytes());
            }
        }
    }

    let context = Context {
        owned: owned_keys(&account_xpub, &used_indices)?,
        start: body.validity_start_interval_bignum().and_then(|slot| slot.to_str().parse().ok()),
        ttl: body.ttl_bignum().and_then(|slot| slot.to_str().parse().ok()),
        valid,
    };

    let resolved: HashMap<(Vec<u8>, u32), &CardanoResolvedOutputFfi> = owned_outputs
        .iter()
        .map(|output| ((output.tx_hash.clone(), output.output_index), output))
        .collect();
    let referenced: HashSet<(Vec<u8>, u32)> = reference_outputs
        .iter()
        .map(|output| (output.tx_hash.clone(), output.output_index))
        .collect();

    let mut requirements = vec![];
    let mut unresolved = BTreeSet::new();

    let spent = body.inputs();
    let collateral = body.collateral();
    let spending = (0..spent.len()).map(|index| spent.get(index)).chain(
        collateral
            .iter()
            .flat_map(|inputs| (0..inputs.len()).map(|index| inputs.get(index))),
    );
    for input in spending {
        let key = (input.transaction_id().to_bytes(), input.index());
        let label = format!("input {}#{}", hex::encode(&key.0), key.1);
        match resolved.get(&key).and_then(|output| address_requirement(&output.address)) {
            Some(found) => requirements.push(found),
            None => {
                unresolved.insert(label);
            }
        }
    }

    if let Some(inputs) = body.reference_inputs() {
        for index in 0..inputs.len() {
            let input = inputs.get(index);
            let key = (input.transaction_id().to_bytes(), input.index());
            if !referenced.contains(&key) {
                unresolved.insert(format!("reference input {}#{}", hex::encode(&key.0), key.1));
            }
        }
    }

    if let Some(signers) = body.required_signers() {
        for index in 0..signers.len() {
            requirements.push(Requirement::Key(signers.get(index).to_bytes()));
        }
    }

    if let Some(withdrawals) = body.withdrawals() {
        let accounts = withdrawals.keys();
        for index in 0..accounts.len() {
            match requirement(&accounts.get(index).payment_cred()) {
                Some(found) => requirements.push(found),
                None => {
                    unresolved.insert("withdrawal".to_string());
                }
            }
        }
    }

    if let Some(certs) = body.certs() {
        for index in 0..certs.len() {
            match certificate_requirement(&certs.get(index)) {
                CertificateRequirement::None => {}
                CertificateRequirement::Credential(credential) => match requirement(&credential) {
                    Some(found) => requirements.push(found),
                    None => {
                        unresolved.insert("certificate credential".to_string());
                    }
                },
                CertificateRequirement::Foreign => {
                    unresolved.insert("pool or governance certificate".to_string());
                }
            }
        }
    }

    if let Some(mint) = body.mint() {
        let policies = mint.keys();
        for index in 0..policies.len() {
            requirements.push(Requirement::Script(policies.get(index).to_bytes()));
        }
    }

    if body.voting_procedures().is_some_and(|votes| votes.get_voters().len() > 0) {
        unresolved.insert("governance vote".to_string());
    }

    // Script bodies: witness set first, then what the caller fetched.
    let mut native_by_hash: BTreeMap<Vec<u8>, NativeScript> = BTreeMap::new();
    let mut plutus_hashes: HashSet<Vec<u8>> = HashSet::new();
    if let Some(natives) = witnesses.native_scripts() {
        for index in 0..natives.len() {
            let script = natives.get(index);
            native_by_hash.insert(script.hash().to_bytes(), script);
        }
    }
    if let Some(plutus) = witnesses.plutus_scripts() {
        for index in 0..plutus.len() {
            plutus_hashes.insert(plutus.get(index).hash().to_bytes());
        }
    }
    for script in &scripts {
        match &script.native_script {
            Some(bytes) => {
                let parsed = native_script(bytes)?;
                if parsed.hash().to_bytes() != script.hash {
                    return Err(signing_failed("Resolved Cardano script does not match its hash"));
                }
                native_by_hash.insert(script.hash.clone(), parsed);
            }
            None => {
                plutus_hashes.insert(script.hash.clone());
            }
        }
    }

    let mut to_sign = BTreeSet::new();
    let mut satisfied = BTreeSet::new();
    let mut missing = BTreeSet::new();

    for requirement in requirements {
        match requirement {
            Requirement::Key(hash) => {
                if context.valid.contains(&hash) {
                    satisfied.insert(hash);
                } else if context.owned.contains_key(&hash) {
                    to_sign.insert(hash);
                } else {
                    missing.insert(hash);
                }
            }
            Requirement::Script(hash) => {
                if plutus_hashes.contains(&hash) {
                    continue;
                }
                let Some(script) = native_by_hash.get(&hash) else {
                    unresolved.insert(format!(
                        "script {}",
                        hex::encode(ScriptHash::from_bytes(hash).map(|h| h.to_bytes()).unwrap_or_default())
                    ));
                    continue;
                };
                match evaluate(script, &context) {
                    Ok(keys) => to_sign.extend(keys),
                    Err(()) => missing_leaves(script, &context, &mut missing),
                }
            }
        }
    }

    let mut paths: Vec<_> = to_sign
        .iter()
        .filter_map(|hash| context.owned.get(hash).copied())
        .collect();
    paths.sort_unstable();
    paths.dedup();

    Ok(CardanoSignersFfi {
        missing: missing.into_iter().collect(),
        satisfied: satisfied.into_iter().collect(),
        to_sign: paths.into_iter().map(path).collect(),
        unresolved: unresolved.into_iter().collect(),
        valid_existing_count: context.valid.len() as u32,
    })
}

/// Maps a CIP-30 `signData` address to the account key that must sign: the
/// payment key of a base/enterprise/pointer address, or the stake key of a
/// reward address. `None` means the account holds no such key
/// (`DataSignError.AddressNotPK`).
#[uniffi::export]
pub fn cardano_classify_signing_address(
    address: Vec<u8>,
    account_xpub: String,
    used_indices: Vec<CardanoUsedIndicesFfi>,
) -> Result<Option<CardanoSigningPathFfi>, WalletKitErrorFfi> {
    let address = Address::from_bytes(address).map_err(invalid_address)?;
    let Some(hash) = address.payment_cred().and_then(|credential| credential.to_keyhash()) else {
        return Ok(None);
    };

    Ok(owned_keys(&account_xpub, &used_indices)?.get(&hash.to_bytes()).copied().map(path))
}
