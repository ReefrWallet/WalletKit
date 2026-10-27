//! Witness-only signing of a dapp transaction (CIP-30 `signTx`).

use cardano_serialization_lib::{make_vkey_witness, Bip32PrivateKey, TransactionWitnessSet, Vkeywitnesses};

use super::decode::parse_transaction;
use crate::blockchain_clients::cardano::{signing_failed, CardanoSigningPathFfi};
use crate::errors::WalletKitErrorFfi;

const CARDANO_COIN_TYPE: u32 = 1815;
const CIP1852_PURPOSE: u32 = 1852;
const HARDENED: u32 = 0x8000_0000;
/// Payment (0), change (1) and stake (2) roles.
const MAX_ROLE: u32 = 2;

/// Signs the hash of the dapp's original body bytes with `signing_paths` and
/// returns a fresh witness set holding only those vkey witnesses. Nothing from
/// the input's witness set, scripts, redeemers or auxiliary data is echoed.
#[uniffi::export]
pub fn cardano_sign_dapp_transaction(
    entropy: Vec<u8>,
    account_index: u32,
    signing_paths: Vec<CardanoSigningPathFfi>,
    transaction: Vec<u8>,
) -> Result<Vec<u8>, WalletKitErrorFfi> {
    if entropy.is_empty() {
        return Err(WalletKitErrorFfi::InvalidEntropy);
    }
    if signing_paths.is_empty() {
        return Err(signing_failed("Cardano transaction has no signing paths"));
    }
    if signing_paths.iter().any(|path| path.role > MAX_ROLE) {
        return Err(signing_failed("Cardano signing path has an unsupported role"));
    }

    let body_hash = parse_transaction(&transaction)?.transaction_hash();
    let account = Bip32PrivateKey::from_bip39_entropy(&entropy, &[])
        .derive(CIP1852_PURPOSE | HARDENED)
        .derive(CARDANO_COIN_TYPE | HARDENED)
        .derive(account_index | HARDENED);

    let mut paths: Vec<_> = signing_paths.iter().map(|path| (path.role, path.index)).collect();
    paths.sort_unstable();
    paths.dedup();

    let mut witnesses = Vkeywitnesses::new();
    for (role, index) in paths {
        let key = account.derive(role).derive(index).to_raw_key();
        witnesses.add(&make_vkey_witness(&body_hash, &key));
    }

    let mut witness_set = TransactionWitnessSet::new();
    witness_set.set_vkeys(&witnesses);
    Ok(witness_set.to_bytes())
}
