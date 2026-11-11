//! Witness-only signing of a dapp transaction (CIP-30 `signTx`).

use cardano_serialization_lib::{make_vkey_witness, TransactionWitnessSet, Vkeywitnesses};

use super::decode::parse_transaction;
use crate::blockchain_clients::cardano::{account_private_key, signing_failed, CardanoRootSecretFfi, CardanoSigningPathFfi};
use crate::errors::WalletKitErrorFfi;

/// Payment (0), change (1) and stake (2) roles.
const MAX_ROLE: u32 = 2;

/// Signs the hash of the dapp's original body bytes with `signing_paths` and
/// returns a fresh witness set holding only those vkey witnesses. Nothing from
/// the input's witness set, scripts, redeemers or auxiliary data is echoed.
#[uniffi::export]
pub fn cardano_sign_dapp_transaction(
    root: CardanoRootSecretFfi,
    account_index: u32,
    signing_paths: Vec<CardanoSigningPathFfi>,
    transaction: Vec<u8>,
) -> Result<Vec<u8>, WalletKitErrorFfi> {
    let account = account_private_key(&root, account_index)?;
    if signing_paths.is_empty() {
        return Err(signing_failed("Cardano transaction has no signing paths"));
    }
    if signing_paths.iter().any(|path| path.role > MAX_ROLE) {
        return Err(signing_failed("Cardano signing path has an unsupported role"));
    }

    let body_hash = parse_transaction(&transaction)?.transaction_hash();

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
