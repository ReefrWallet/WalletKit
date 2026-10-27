use blake2::digest::consts::U32;
use blake2::{Blake2b, Digest};
use cardano_serialization_lib::{
    make_vkey_witness, Address, AssetName, BigNum, Bip32PrivateKey, Certificate, Certificates, Credential,
    Ed25519KeyHash, Ed25519KeyHashes, Int, Mint, MintAssets, NativeScript, NativeScripts, PlutusData, PrivateKey,
    RewardAddress, ScriptAll, ScriptAny, ScriptHash, ScriptNOfK, ScriptPubkey, StakeDelegation,
    TimelockExpiry, Transaction, TransactionBody, TransactionHash, TransactionInput, TransactionInputs,
    TransactionOutput, TransactionOutputs, TransactionWitnessSet, Value, Vkeywitnesses, Withdrawals,
};

use super::*;
use crate::blockchain_clients::cardano::{
    cardano_account_xpub_from_entropy, cardano_base_address, cardano_stake_address, CardanoAssetFfi, CardanoSigningPathFfi,
    CardanoUtxoFfi,
};

const ENTROPY: [u8; 16] = [0; 16];
const FOREIGN_ENTROPY: [u8; 16] = [9; 16];
const NETWORK: u8 = 0;

fn account_key(entropy: &[u8], role: u32, index: u32) -> PrivateKey {
    Bip32PrivateKey::from_bip39_entropy(entropy, &[])
        .derive(1852 | 0x8000_0000)
        .derive(1815 | 0x8000_0000)
        .derive(0x8000_0000)
        .derive(role)
        .derive(index)
        .to_raw_key()
}

fn key_hash(entropy: &[u8], role: u32, index: u32) -> Ed25519KeyHash {
    account_key(entropy, role, index).to_public().hash()
}

fn xpub() -> String {
    cardano_account_xpub_from_entropy(ENTROPY.to_vec(), 0).unwrap()
}

fn address(index: u32) -> String {
    cardano_base_address(xpub(), NETWORK, 0, index).unwrap()
}

fn input(seed: u8, index: u32) -> TransactionInput {
    TransactionInput::new(&TransactionHash::from_bytes(vec![seed; 32]).unwrap(), index)
}

fn owned(seed: u8, index: u32, address_index: u32) -> CardanoResolvedOutputFfi {
    CardanoResolvedOutputFfi {
        address: address(address_index),
        output_index: index,
        script_hash: None,
        tx_hash: vec![seed; 32],
    }
}

fn body(inputs: &[TransactionInput]) -> TransactionBody {
    let mut spent = TransactionInputs::new();
    for input in inputs {
        spent.add(input);
    }
    let mut outputs = TransactionOutputs::new();
    outputs.add(&TransactionOutput::new(
        &Address::from_bech32(&address(0)).unwrap(),
        &Value::new(&BigNum::from_str("2000000").unwrap()),
    ));
    TransactionBody::new_tx_body(&spent, &outputs, &BigNum::from_str("170000").unwrap())
}

fn transaction(body: &TransactionBody, witnesses: &TransactionWitnessSet) -> Vec<u8> {
    Transaction::new(body, witnesses, None).to_bytes()
}

fn body_hash(body: &TransactionBody) -> TransactionHash {
    TransactionHash::from_bytes(Blake2b::<U32>::digest(body.to_bytes()).to_vec()).unwrap()
}

fn witness_set(witnesses: &[(&PrivateKey, &TransactionHash)]) -> TransactionWitnessSet {
    let mut vkeys = Vkeywitnesses::new();
    for (key, hash) in witnesses {
        vkeys.add(&make_vkey_witness(hash, key));
    }
    let mut set = TransactionWitnessSet::new();
    set.set_vkeys(&vkeys);
    set
}

fn signers(transaction: &[u8], owned_outputs: Vec<CardanoResolvedOutputFfi>) -> CardanoSignersFfi {
    cardano_required_signers(transaction.to_vec(), xpub(), owned_outputs, vec![], vec![], vec![]).unwrap()
}

fn path(role: u32, index: u32) -> CardanoSigningPathFfi {
    CardanoSigningPathFfi { index, role }
}

fn pubkey_script(hash: &Ed25519KeyHash) -> NativeScript {
    NativeScript::new_script_pubkey(&ScriptPubkey::new(hash))
}

fn scripts(list: &[NativeScript]) -> NativeScripts {
    let mut result = NativeScripts::new();
    for script in list {
        result.add(script);
    }
    result
}

/// A body minting one token under `script`, spending an owned input.
fn minting_body(script: &NativeScript) -> TransactionBody {
    let mut body = body(&[input(1, 0)]);
    let mut assets = MintAssets::new();
    assets.insert(&AssetName::new(b"T".to_vec()).unwrap(), &Int::new_i32(1)).unwrap();
    body.set_mint(&Mint::new_from_entry(&script.hash(), &assets));
    body
}

fn minting_witnesses(script: &NativeScript) -> TransactionWitnessSet {
    let mut set = TransactionWitnessSet::new();
    set.set_native_scripts(&scripts(&[script.clone()]));
    set
}

#[test]
fn body_hash_comes_from_the_original_bytes() {
    // Same body as `body(..)` but with its map keys out of canonical order
    // (0, 2, 1), so a re-serialized body would hash differently.
    let source = body(&[input(1, 0)]);
    let mut raw_body = vec![0xA3, 0x00];
    raw_body.extend(source.inputs().to_bytes());
    raw_body.push(0x02);
    raw_body.extend(source.fee().to_bytes());
    raw_body.push(0x01);
    raw_body.extend(source.outputs().to_bytes());
    let mut raw_tx = vec![0x84];
    raw_tx.extend(&raw_body);
    raw_tx.extend([0xA0, 0xF5, 0xF6]);

    let expected = Blake2b::<U32>::digest(&raw_body).to_vec();

    assert_eq!(cardano_transaction_hash(raw_tx.clone()).unwrap(), expected);
    assert_ne!(
        Blake2b::<U32>::digest(TransactionBody::from_bytes(raw_body).unwrap().to_bytes()).to_vec(),
        expected,
        "fixture must be non-canonical for this test to mean anything"
    );
    assert_eq!(cardano_decode_transaction(raw_tx).unwrap().body_hash, expected);
}

#[test]
fn trailing_bytes_are_rejected() {
    let mut tx = transaction(&body(&[input(1, 0)]), &TransactionWitnessSet::new());
    tx.push(0x00);

    assert!(cardano_decode_transaction(tx.clone()).is_err());
    assert!(cardano_transaction_hash(tx).is_err());
}

#[test]
fn decode_reports_preview_fields() {
    let mut body = minting_body(&pubkey_script(&key_hash(&ENTROPY, 0, 0)));
    body.set_ttl(&BigNum::from_str("1000").unwrap());
    body.set_validity_start_interval_bignum(&BigNum::from_str("10").unwrap());
    let mut keys = Ed25519KeyHashes::new();
    keys.add(&key_hash(&FOREIGN_ENTROPY, 0, 0));
    body.set_required_signers(&keys);

    let decoded = cardano_decode_transaction(transaction(&body, &TransactionWitnessSet::new())).unwrap();

    assert_eq!(decoded.fee, "170000");
    assert_eq!(decoded.inputs.len(), 1);
    assert_eq!(decoded.outputs.len(), 1);
    assert_eq!(decoded.outputs[0].lovelace, "2000000");
    assert_eq!(decoded.ttl.as_deref(), Some("1000"));
    assert_eq!(decoded.validity_start.as_deref(), Some("10"));
    assert_eq!(decoded.required_signers, vec![key_hash(&FOREIGN_ENTROPY, 0, 0).to_bytes()]);
    assert_eq!(decoded.mint.len(), 1);
    assert_eq!(decoded.mint[0].quantity, "1");
    assert!(decoded.is_valid);
}

#[test]
fn signing_returns_only_new_vkeys_and_drops_existing_witnesses() {
    let body = body(&[input(1, 0)]);
    let hash = body_hash(&body);
    let foreign = account_key(&FOREIGN_ENTROPY, 0, 0);
    let script = pubkey_script(&key_hash(&FOREIGN_ENTROPY, 0, 1));
    let mut existing = witness_set(&[(&foreign, &hash)]);
    existing.set_native_scripts(&scripts(&[script]));
    let tx = transaction(&body, &existing);

    let witnesses = cardano_sign_dapp_transaction(ENTROPY.to_vec(), 0, vec![path(0, 0)], tx).unwrap();
    let witnesses = TransactionWitnessSet::from_bytes(witnesses).unwrap();
    let vkeys = witnesses.vkeys().unwrap();

    assert_eq!(vkeys.len(), 1);
    assert_eq!(vkeys.get(0).vkey().public_key().hash(), key_hash(&ENTROPY, 0, 0));
    assert!(vkeys.get(0).vkey().public_key().verify(&hash.to_bytes(), &vkeys.get(0).signature()));
    assert!(witnesses.native_scripts().is_none());
    assert!(witnesses.plutus_scripts().is_none());
    assert!(witnesses.redeemers().is_none());
}

#[test]
fn signing_deduplicates_paths_and_rejects_bad_requests() {
    let tx = transaction(&body(&[input(1, 0)]), &TransactionWitnessSet::new());

    let set = cardano_sign_dapp_transaction(ENTROPY.to_vec(), 0, vec![path(0, 0), path(0, 0)], tx.clone()).unwrap();
    assert_eq!(TransactionWitnessSet::from_bytes(set).unwrap().vkeys().unwrap().len(), 1);

    assert!(cardano_sign_dapp_transaction(vec![], 0, vec![path(0, 0)], tx.clone()).is_err());
    assert!(cardano_sign_dapp_transaction(ENTROPY.to_vec(), 0, vec![], tx.clone()).is_err());
    assert!(cardano_sign_dapp_transaction(ENTROPY.to_vec(), 0, vec![path(3, 0)], tx).is_err());
}

#[test]
fn owned_input_needs_its_payment_key() {
    let tx = transaction(&body(&[input(1, 0), input(2, 1)]), &TransactionWitnessSet::new());

    let result = signers(&tx, vec![owned(1, 0, 0), owned(2, 1, 3)]);

    assert_eq!(result.to_sign, vec![path(0, 0), path(0, 3)]);
    assert!(result.missing.is_empty());
    assert!(result.unresolved.is_empty());
}

#[test]
fn unresolved_input_is_not_missing() {
    let tx = transaction(&body(&[input(1, 0), input(7, 7)]), &TransactionWitnessSet::new());

    let result = signers(&tx, vec![owned(1, 0, 0)]);

    assert_eq!(result.to_sign, vec![path(0, 0)]);
    assert!(result.missing.is_empty());
    assert_eq!(result.unresolved.len(), 1);
}

#[test]
fn collateral_inputs_need_signing_too() {
    let mut body = body(&[input(1, 0)]);
    let mut collateral = TransactionInputs::new();
    collateral.add(&input(2, 0));
    body.set_collateral(&collateral);

    let result = signers(
        &transaction(&body, &TransactionWitnessSet::new()),
        vec![owned(1, 0, 0), owned(2, 0, 1)],
    );

    assert_eq!(result.to_sign, vec![path(0, 0), path(0, 1)]);
}

#[test]
fn required_signers_withdrawals_and_certificates() {
    let foreign = key_hash(&FOREIGN_ENTROPY, 0, 0);
    let stake = RewardAddress::from_address(&Address::from_bech32(&cardano_stake_address(xpub(), NETWORK).unwrap()).unwrap())
        .unwrap();
    let mut body = body(&[input(1, 0)]);
    let mut required = Ed25519KeyHashes::new();
    required.add(&foreign);
    body.set_required_signers(&required);
    let mut withdrawals = Withdrawals::new();
    withdrawals.insert(&stake, &BigNum::from_str("5").unwrap());
    body.set_withdrawals(&withdrawals);

    let result = signers(&transaction(&body, &TransactionWitnessSet::new()), vec![owned(1, 0, 0)]);

    assert_eq!(result.to_sign, vec![path(0, 0), path(2, 0)]);
    assert_eq!(result.missing, vec![foreign.to_bytes()]);

    // A delegation also needs the stake key.
    let mut certs = Certificates::new();
    certs.add(&Certificate::new_stake_delegation(&StakeDelegation::new(
        &Credential::from_keyhash(&key_hash(&ENTROPY, 2, 0)),
        &foreign,
    )));
    let mut delegation = body_with_input();
    delegation.set_certs(&certs);
    let result = signers(&transaction(&delegation, &TransactionWitnessSet::new()), vec![owned(1, 0, 0)]);
    assert_eq!(result.to_sign, vec![path(0, 0), path(2, 0)]);
}

fn body_with_input() -> TransactionBody {
    body(&[input(1, 0)])
}

#[test]
fn pool_certificates_are_unresolved() {
    let mut certs = Certificates::new();
    certs.add(&Certificate::new_pool_retirement(&cardano_serialization_lib::PoolRetirement::new(
        &cardano_serialization_lib::Ed25519KeyHash::from_bytes(vec![5; 28]).unwrap(),
        10,
    )));
    let mut body = body_with_input();
    body.set_certs(&certs);

    let result = signers(&transaction(&body, &TransactionWitnessSet::new()), vec![owned(1, 0, 0)]);

    assert_eq!(result.unresolved.len(), 1);
}

#[test]
fn valid_foreign_cosigner_satisfies_a_required_signer() {
    let foreign = account_key(&FOREIGN_ENTROPY, 0, 0);
    let mut body = body_with_input();
    let mut required = Ed25519KeyHashes::new();
    required.add(&foreign.to_public().hash());
    body.set_required_signers(&required);
    let witnesses = witness_set(&[(&foreign, &body_hash(&body))]);

    let result = signers(&transaction(&body, &witnesses), vec![owned(1, 0, 0)]);

    assert!(result.missing.is_empty());
    assert_eq!(result.satisfied, vec![foreign.to_public().hash().to_bytes()]);
    assert_eq!(result.valid_existing_count, 1);
    assert_eq!(result.to_sign, vec![path(0, 0)]);
}

#[test]
fn invalid_foreign_witness_is_not_counted() {
    let foreign = account_key(&FOREIGN_ENTROPY, 0, 0);
    let mut body = body_with_input();
    let mut required = Ed25519KeyHashes::new();
    required.add(&foreign.to_public().hash());
    body.set_required_signers(&required);
    // Signed over a different hash, so it can't verify.
    let witnesses = witness_set(&[(&foreign, &TransactionHash::from_bytes(vec![3; 32]).unwrap())]);

    let result = signers(&transaction(&body, &witnesses), vec![owned(1, 0, 0)]);

    assert_eq!(result.missing, vec![foreign.to_public().hash().to_bytes()]);
    assert!(result.satisfied.is_empty());
    assert_eq!(result.valid_existing_count, 0);
}

#[test]
fn already_valid_owned_witness_is_not_signed_again() {
    let body = body_with_input();
    let owned_key = account_key(&ENTROPY, 0, 0);
    let witnesses = witness_set(&[(&owned_key, &body_hash(&body))]);

    let result = signers(&transaction(&body, &witnesses), vec![owned(1, 0, 0)]);

    assert!(result.to_sign.is_empty());
    assert_eq!(result.satisfied, vec![owned_key.to_public().hash().to_bytes()]);
}

fn resolve(script: &NativeScript, body: &TransactionBody) -> CardanoSignersFfi {
    signers(&transaction(body, &minting_witnesses(script)), vec![owned(1, 0, 0)])
}

#[test]
fn native_all_requires_every_leaf() {
    let mine = key_hash(&ENTROPY, 0, 5);
    let theirs = key_hash(&FOREIGN_ENTROPY, 0, 0);
    let script = NativeScript::new_script_all(&ScriptAll::new(&scripts(&[pubkey_script(&mine), pubkey_script(&theirs)])));

    let result = resolve(&script, &minting_body(&script));

    assert_eq!(result.missing, vec![theirs.to_bytes()]);
}

#[test]
fn native_any_is_satisfied_by_one_owned_leaf() {
    let mine = key_hash(&ENTROPY, 0, 5);
    let theirs = key_hash(&FOREIGN_ENTROPY, 0, 0);
    let script = NativeScript::new_script_any(&ScriptAny::new(&scripts(&[pubkey_script(&theirs), pubkey_script(&mine)])));

    let result = resolve(&script, &minting_body(&script));

    assert!(result.missing.is_empty());
    assert_eq!(result.to_sign, vec![path(0, 0), path(0, 5)]);
}

#[test]
fn native_n_of_k_counts_threshold() {
    let mine = key_hash(&ENTROPY, 0, 5);
    let theirs = key_hash(&FOREIGN_ENTROPY, 0, 0);
    let other = key_hash(&FOREIGN_ENTROPY, 0, 1);
    let leaves = scripts(&[pubkey_script(&mine), pubkey_script(&theirs), pubkey_script(&other)]);

    let two = NativeScript::new_script_n_of_k(&ScriptNOfK::new(2, &leaves));
    let unsatisfied = resolve(&two, &minting_body(&two));
    assert_eq!(unsatisfied.missing.len(), 2);

    let one = NativeScript::new_script_n_of_k(&ScriptNOfK::new(1, &leaves));
    assert!(resolve(&one, &minting_body(&one)).missing.is_empty());
}

#[test]
fn native_leaf_is_satisfied_by_a_valid_cosigner() {
    let mine = key_hash(&ENTROPY, 0, 5);
    let foreign = account_key(&FOREIGN_ENTROPY, 0, 0);
    let script = NativeScript::new_script_all(&ScriptAll::new(&scripts(&[
        pubkey_script(&mine),
        pubkey_script(&foreign.to_public().hash()),
    ])));
    let body = minting_body(&script);
    let mut witnesses = minting_witnesses(&script);
    witnesses.set_vkeys(&{
        let mut vkeys = Vkeywitnesses::new();
        vkeys.add(&make_vkey_witness(&body_hash(&body), &foreign));
        vkeys
    });

    let result = signers(&transaction(&body, &witnesses), vec![owned(1, 0, 0)]);

    assert!(result.missing.is_empty());
    assert_eq!(result.to_sign, vec![path(0, 0), path(0, 5)]);
}

#[test]
fn native_timelock_uses_the_validity_interval() {
    let expiry = NativeScript::new_timelock_expiry(&TimelockExpiry::new_timelockexpiry(&BigNum::from_str("100").unwrap()));
    let mine = pubkey_script(&key_hash(&ENTROPY, 0, 5));
    let script = NativeScript::new_script_all(&ScriptAll::new(&scripts(&[mine, expiry])));

    let mut open = minting_body(&script);
    let unbounded = resolve(&script, &open);
    assert_eq!(unbounded.to_sign, vec![path(0, 0)], "an unbounded tx can't satisfy an expiry");

    open.set_ttl(&BigNum::from_str("90").unwrap());
    assert_eq!(resolve(&script, &open).to_sign, vec![path(0, 0), path(0, 5)]);
}

#[test]
fn unreferenced_native_script_in_the_witness_set_is_ignored() {
    let theirs = key_hash(&FOREIGN_ENTROPY, 0, 0);
    let stray = pubkey_script(&theirs);
    let tx = transaction(&body_with_input(), &minting_witnesses(&stray));

    let result = signers(&tx, vec![owned(1, 0, 0)]);

    assert!(result.missing.is_empty());
    assert!(result.unresolved.is_empty());
}

#[test]
fn unknown_script_and_reference_input_are_unresolved() {
    let script = pubkey_script(&key_hash(&ENTROPY, 0, 5));
    let mut body = minting_body(&script);
    let mut references = TransactionInputs::new();
    references.add(&input(8, 0));
    body.set_reference_inputs(&references);

    let unknown = signers(&transaction(&body, &TransactionWitnessSet::new()), vec![owned(1, 0, 0)]);
    assert_eq!(unknown.unresolved.len(), 2);

    let resolved = cardano_required_signers(
        transaction(&body, &TransactionWitnessSet::new()),
        xpub(),
        vec![owned(1, 0, 0)],
        vec![CardanoResolvedOutputFfi {
            address: address(0),
            output_index: 0,
            script_hash: Some(script.hash().to_bytes()),
            tx_hash: vec![8; 32],
        }],
        vec![CardanoResolvedScriptFfi {
            hash: script.hash().to_bytes(),
            native_script: Some(script.to_bytes()),
        }],
        vec![],
    )
    .unwrap();
    assert!(resolved.unresolved.is_empty());
    assert_eq!(resolved.to_sign, vec![path(0, 0), path(0, 5)]);
}

#[test]
fn resolved_script_must_match_its_hash() {
    let script = pubkey_script(&key_hash(&ENTROPY, 0, 5));
    let body = minting_body(&script);

    let result = cardano_required_signers(
        transaction(&body, &TransactionWitnessSet::new()),
        xpub(),
        vec![owned(1, 0, 0)],
        vec![],
        vec![CardanoResolvedScriptFfi {
            hash: ScriptHash::from_bytes(vec![1; 28]).unwrap().to_bytes(),
            native_script: Some(script.to_bytes()),
        }],
        vec![],
    );

    assert!(result.is_err());
}

#[test]
fn plutus_scripts_need_no_key_witness() {
    let script = pubkey_script(&key_hash(&ENTROPY, 0, 5));
    let body = minting_body(&script);

    let result = cardano_required_signers(
        transaction(&body, &TransactionWitnessSet::new()),
        xpub(),
        vec![owned(1, 0, 0)],
        vec![],
        vec![CardanoResolvedScriptFfi {
            hash: script.hash().to_bytes(),
            native_script: None,
        }],
        vec![],
    )
    .unwrap();

    assert!(result.unresolved.is_empty());
    assert!(result.missing.is_empty());
}

#[test]
fn classify_maps_addresses_to_account_keys() {
    let payment = cardano_address_to_bytes(address(4)).unwrap();
    let reward = cardano_address_to_bytes(cardano_stake_address(xpub(), NETWORK).unwrap()).unwrap();
    let foreign = cardano_address_to_bytes(cardano_base_address(
        cardano_account_xpub_from_entropy(FOREIGN_ENTROPY.to_vec(), 0).unwrap(),
        NETWORK,
        0,
        0,
    )
    .unwrap())
    .unwrap();

    assert_eq!(cardano_classify_signing_address(payment, xpub(), vec![]).unwrap(), Some(path(0, 4)));
    assert_eq!(cardano_classify_signing_address(reward, xpub(), vec![]).unwrap(), Some(path(2, 0)));
    assert_eq!(cardano_classify_signing_address(foreign, xpub(), vec![]).unwrap(), None);
}

#[test]
fn cip8_signature_verifies_over_the_unhashed_payload() {
    let address = cardano_address_to_bytes(address(0)).unwrap();
    let payload = b"hello reefr".to_vec();

    let result = cardano_cip8_sign_data(ENTROPY.to_vec(), 0, path(0, 0), address.clone(), payload.clone()).unwrap();

    let key = account_key(&ENTROPY, 0, 0).to_public();
    // COSE_Sign1 is a 4-element array: protected, unprotected, payload, signature.
    assert_eq!(result.signature[0], 0x84);
    let signature = &result.signature[result.signature.len() - 64..];
    let structure = cip8::structure_for_tests(&address, &payload);
    assert!(key.verify(&structure, &cardano_serialization_lib::Ed25519Signature::from_bytes(signature.to_vec()).unwrap()));
    // The payload appears verbatim: it is not hashed.
    assert!(result.signature.windows(payload.len()).any(|window| window == payload.as_slice()));
    // Unprotected header: {"hashed": false, "version": 1}.
    let unprotected = [
        &[0xA2, 0x66][..],
        b"hashed",
        &[0xF4, 0x67],
        b"version",
        &[0x01],
    ]
    .concat();
    assert!(result.signature.windows(unprotected.len()).any(|window| window == unprotected.as_slice()));
    // COSE_Key: {1: 1, 3: -8, -1: 6, -2: pubkey}
    assert_eq!(&result.key[..8], &[0xA4, 0x01, 0x01, 0x03, 0x27, 0x20, 0x06, 0x21]);
    assert_eq!(&result.key[result.key.len() - 32..], key.as_bytes().as_slice());
}

#[test]
fn cip8_assemble_matches_software_signing() {
    let address = cardano_address_to_bytes(address(0)).unwrap();
    let payload = vec![1, 2, 3];
    let signed = cardano_cip8_sign_data(ENTROPY.to_vec(), 0, path(0, 0), address.clone(), payload.clone()).unwrap();
    let key = account_key(&ENTROPY, 0, 0);
    let signature = key.sign(&cip8::structure_for_tests(&address, &payload));

    let assembled =
        cardano_cip8_assemble(signature.to_bytes(), key.to_public().as_bytes(), address, payload).unwrap();

    assert_eq!(assembled, signed);
    assert!(cardano_cip8_assemble(vec![0; 63], vec![0; 32], vec![], vec![]).is_err());
    assert!(cardano_cip8_assemble(vec![0; 64], vec![0; 31], vec![], vec![]).is_err());
}

fn asset(name: &str, quantity: &str) -> CardanoAssetFfi {
    CardanoAssetFfi {
        name: name.as_bytes().to_vec(),
        policy_id: vec![7; 28],
        quantity: quantity.to_string(),
    }
}

#[test]
fn value_round_trips_through_cbor() {
    let plain = CardanoValueFfi { assets: vec![], lovelace: "1500000".into() };
    assert_eq!(cardano_value_to_hex(plain.clone()).unwrap(), "1a0016e360");
    assert_eq!(cardano_value_from_hex(cardano_value_to_hex(plain.clone()).unwrap()).unwrap(), plain);

    let multi = CardanoValueFfi { assets: vec![asset("T", "5")], lovelace: "2000000".into() };
    assert_eq!(cardano_value_from_hex(cardano_value_to_hex(multi.clone()).unwrap()).unwrap(), multi);
}

#[test]
fn utxo_round_trips_with_datum_and_script_ref() {
    let script = pubkey_script(&key_hash(&ENTROPY, 0, 0));
    let utxo = CardanoDappUtxoFfi {
        address: address(0),
        assets: vec![asset("T", "5")],
        datum_hash: None,
        inline_datum: Some(PlutusData::new_integer(&cardano_serialization_lib::BigInt::from_str("42").unwrap()).to_bytes()),
        lovelace: "2000000".into(),
        output_index: 3,
        script_ref: Some(cardano_script_ref_native(script.to_bytes()).unwrap()),
        tx_hash: vec![1; 32],
    };

    let hex = cardano_utxo_to_hex(utxo.clone()).unwrap();

    assert_eq!(cardano_utxo_from_hex(hex).unwrap(), utxo);
}

#[test]
fn address_bytes_round_trip() {
    let bech32 = address(2);

    let bytes = cardano_address_to_bytes(bech32.clone()).unwrap();

    assert_eq!(cardano_address_from_bytes(bytes).unwrap(), bech32);
}

fn utxo(index: u32, lovelace: &str, assets: Vec<CardanoAssetFfi>) -> CardanoUtxoFfi {
    CardanoUtxoFfi {
        address: address(0),
        assets,
        lovelace: lovelace.into(),
        output_index: index,
        tx_hash: vec![index as u8; 32],
    }
}

#[test]
fn utxo_selection_covers_assets_then_coin() {
    let utxos = vec![
        utxo(0, "1000000", vec![]),
        utxo(1, "3000000", vec![asset("T", "2")]),
        utxo(2, "2000000", vec![asset("T", "10")]),
        utxo(3, "9000000", vec![]),
    ];

    // 10 T is covered by UTxO 2 alone (largest first); 5 ADA then needs UTxO 3.
    let target = CardanoValueFfi { assets: vec![asset("T", "10")], lovelace: "5000000".into() };
    assert_eq!(cardano_select_utxos(target, utxos.clone()).unwrap(), Some(vec![2, 3]));

    // 11 T needs both token UTxOs; their 5 ADA covers the coin target.
    let target = CardanoValueFfi { assets: vec![asset("T", "11")], lovelace: "5000000".into() };
    assert_eq!(cardano_select_utxos(target, utxos.clone()).unwrap(), Some(vec![1, 2]));

    let unreachable = CardanoValueFfi { assets: vec![asset("T", "13")], lovelace: "0".into() };
    assert_eq!(cardano_select_utxos(unreachable, utxos.clone()).unwrap(), None);

    let too_much_ada = CardanoValueFfi { assets: vec![], lovelace: "20000000".into() };
    assert_eq!(cardano_select_utxos(too_much_ada, utxos).unwrap(), None);
}

#[test]
fn native_script_json_matches_the_cbor_script_hash() {
    let mine = key_hash(&ENTROPY, 0, 0);
    let theirs = key_hash(&FOREIGN_ENTROPY, 0, 0);
    let expected = NativeScript::new_script_all(&ScriptAll::new(&scripts(&[
        pubkey_script(&mine),
        NativeScript::new_script_n_of_k(&ScriptNOfK::new(1, &scripts(&[pubkey_script(&theirs)]))),
        NativeScript::new_timelock_expiry(&TimelockExpiry::new_timelockexpiry(&BigNum::from_str("100").unwrap())),
    ])));
    let json = format!(
        r#"{{"type":"all","scripts":[
            {{"type":"sig","keyHash":"{}"}},
            {{"type":"atLeast","required":1,"scripts":[{{"type":"sig","keyHash":"{}"}}]}},
            {{"type":"before","slot":100}}
        ]}}"#,
        hex::encode(mine.to_bytes()),
        hex::encode(theirs.to_bytes()),
    );

    let parsed = NativeScript::from_bytes(cardano_native_script_from_json(json).unwrap()).unwrap();

    assert_eq!(parsed.hash(), expected.hash());
    assert!(cardano_native_script_from_json(r#"{"type":"nope"}"#.to_string()).is_err());
}
