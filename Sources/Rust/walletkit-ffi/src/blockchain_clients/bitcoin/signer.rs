//! `BitcoinSignerFfi`: signs a PSBT built by
//! `psbt::bitcoin_build_unsigned_psbt` and finalizes it into a broadcastable
//! raw transaction. All secp256k1/taproot math (BIP-143 ECDSA sighashing,
//! BIP-341 key-path Schnorr sighashing and the BIP-86 taproot tweak) is the
//! `bitcoin` crate's own, audited implementation — this module only
//! supplies the secret scalar and glues the pieces together.

use std::sync::Arc;

use bitcoin::hashes::Hash;
use bitcoin::key::{Keypair, TapTweak};
use bitcoin::psbt::Psbt;
use bitcoin::secp256k1::{ecdsa, schnorr, Message, PublicKey, Secp256k1, SecretKey};
use bitcoin::sighash::{EcdsaSighashType, Prevouts, SighashCache, TapSighashType};
use bitcoin::{TxOut, Witness};

use crate::errors::WalletKitErrorFfi;
use crate::keys::PrivateKeyFfi;

fn signing_failed(reason: impl Into<String>) -> WalletKitErrorFfi {
    WalletKitErrorFfi::SigningFailed { reason: reason.into() }
}

#[derive(Debug, Clone, Copy, uniffi::Object)]
pub struct BitcoinSignerFfi;

impl Default for BitcoinSignerFfi {
    fn default() -> Self {
        Self::new()
    }
}

#[uniffi::export]
impl BitcoinSignerFfi {
    #[uniffi::constructor]
    pub fn new() -> BitcoinSignerFfi {
        BitcoinSignerFfi
    }

    /// Signs every input of `psbt`, matching `keys[i]` to input `i`
    /// positionally — the caller already knows which derived key owns
    /// which UTXO (see `psbt::BitcoinPsbtInputFfi`'s ordering), so this
    /// does not consult the PSBT's own `bip32_derivation`/`tap_key_origins`
    /// to look keys up. A P2WPKH input is signed with BIP-143 ECDSA into
    /// `partial_sigs`; a P2TR input is signed with BIP-341 key-path
    /// Schnorr (after applying the BIP-86 taproot tweak to the supplied
    /// key) into `tap_key_sig`. Returns the same PSBT with those fields
    /// populated — still unfinalized; pass the result to `finalize_psbt`.
    ///
    /// - Throws `.signingFailed` if `psbt` doesn't deserialize,
    ///   `keys.len()` doesn't match `psbt`'s input count, an input has no
    ///   `witness_utxo`, an input's scriptPubKey isn't P2WPKH/P2TR, or a
    ///   supplied key doesn't own the input it's positioned at.
    pub fn sign_psbt(&self, psbt: Vec<u8>, keys: Vec<Arc<PrivateKeyFfi>>) -> Result<Vec<u8>, WalletKitErrorFfi> {
        let mut psbt = Psbt::deserialize(&psbt).map_err(|err| signing_failed(err.to_string()))?;

        if keys.len() != psbt.inputs.len() {
            return Err(signing_failed(format!(
                "expected {} keys (one per input), got {}",
                psbt.inputs.len(),
                keys.len()
            )));
        }

        let secp = Secp256k1::new();
        // Cloning the unsigned tx and every prevout up front — rather than
        // holding a `SighashCache` borrow into `psbt.unsigned_tx` across
        // the loop below — sidesteps a self-referential borrow against
        // `psbt` while the loop also mutates `psbt.inputs[i]`; the
        // `bitcoin` crate's own `Psbt::sign` takes the same approach for
        // the same reason (see its `bip32_sign_ecdsa`/`bip32_sign_schnorr`).
        let tx = psbt.unsigned_tx.clone();
        let prevouts: Vec<TxOut> = psbt
            .inputs
            .iter()
            .enumerate()
            .map(|(i, input)| {
                input.witness_utxo.clone().ok_or_else(|| signing_failed(format!("input {i} has no witness_utxo")))
            })
            .collect::<Result<_, _>>()?;
        let mut cache = SighashCache::new(&tx);

        for (i, key) in keys.iter().enumerate() {
            let script_pubkey = prevouts[i].script_pubkey.clone();
            let secret_key = SecretKey::from_slice(&key.raw_bytes()).map_err(|err| signing_failed(err.to_string()))?;

            if script_pubkey.is_p2tr() {
                let internal_key = psbt.inputs[i]
                    .tap_internal_key
                    .ok_or_else(|| signing_failed(format!("input {i} has no tap_internal_key")))?;

                let public_key = PublicKey::from_secret_key(&secp, &secret_key);
                let (x_only, _parity) = public_key.x_only_public_key();
                if x_only != internal_key {
                    return Err(signing_failed(format!("key {i} does not own this input's taproot output")));
                }

                let sighash = cache
                    .taproot_key_spend_signature_hash(i, &Prevouts::All(&prevouts), TapSighashType::Default)
                    .map_err(|err| signing_failed(err.to_string()))?;
                let message = Message::from_digest(sighash.to_byte_array());

                let keypair = Keypair::from_secret_key(&secp, &secret_key);
                let tweaked = keypair.tap_tweak(&secp, None).to_keypair();
                let signature: schnorr::Signature = secp.sign_schnorr_no_aux_rand(&message, &tweaked);

                psbt.inputs[i].tap_key_sig =
                    Some(bitcoin::taproot::Signature { signature, sighash_type: TapSighashType::Default });
            } else {
                let public_key = PublicKey::from_secret_key(&secp, &secret_key);
                let expected_script = bitcoin::CompressedPublicKey(public_key).p2wpkh_script_code();
                if script_pubkey.p2wpkh_script_code() != Some(expected_script) {
                    return Err(signing_failed(format!("key {i} does not own this input's P2WPKH output")));
                }

                let sighash = cache
                    .p2wpkh_signature_hash(i, &script_pubkey, prevouts[i].value, EcdsaSighashType::All)
                    .map_err(|err| signing_failed(err.to_string()))?;
                let message = Message::from_digest(sighash.to_byte_array());

                let signature: ecdsa::Signature = secp.sign_ecdsa(&message, &secret_key);
                let bitcoin_pk = bitcoin::key::PublicKey::new(public_key);
                psbt.inputs[i]
                    .partial_sigs
                    .insert(bitcoin_pk, bitcoin::ecdsa::Signature::sighash_all(signature));
            }
        }

        Ok(psbt.serialize())
    }

    /// Finalizes a PSBT already signed by `sign_psbt` — builds each
    /// input's final witness from its `partial_sigs` (P2WPKH) or
    /// `tap_key_sig` (P2TR) entry, extracts the resulting `Transaction`,
    /// and returns its raw consensus-serialized bytes, ready to broadcast.
    ///
    /// - Throws `.signingFailed` if `psbt` doesn't deserialize, an input
    ///   has no `witness_utxo`, or an input has neither a `partial_sigs`
    ///   nor a `tap_key_sig` entry (i.e. `sign_psbt` hasn't run for it).
    pub fn finalize_psbt(&self, psbt: Vec<u8>) -> Result<Vec<u8>, WalletKitErrorFfi> {
        let mut psbt = Psbt::deserialize(&psbt).map_err(|err| signing_failed(err.to_string()))?;

        for i in 0..psbt.inputs.len() {
            let script_pubkey = psbt.inputs[i]
                .witness_utxo
                .as_ref()
                .ok_or_else(|| signing_failed(format!("input {i} has no witness_utxo")))?
                .script_pubkey
                .clone();

            let witness = if script_pubkey.is_p2tr() {
                let signature = psbt.inputs[i]
                    .tap_key_sig
                    .ok_or_else(|| signing_failed(format!("input {i} has no tap_key_sig — run sign_psbt first")))?;
                Witness::p2tr_key_spend(&signature)
            } else {
                let (public_key, signature) = psbt.inputs[i]
                    .partial_sigs
                    .iter()
                    .next()
                    .map(|(pk, sig)| (*pk, *sig))
                    .ok_or_else(|| signing_failed(format!("input {i} has no partial_sigs — run sign_psbt first")))?;
                Witness::p2wpkh(&signature, &public_key.inner)
            };

            psbt.inputs[i].final_script_witness = Some(witness);
        }

        let tx = psbt.extract_tx().map_err(|err| signing_failed(err.to_string()))?;
        Ok(bitcoin::consensus::encode::serialize(&tx))
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::blockchain_clients::bitcoin::descriptor::{BitcoinDescriptorFfi, BitcoinScriptTypeFfi};
    use crate::blockchain_clients::bitcoin::network::BitcoinNetworkFfi;
    use crate::blockchain_clients::bitcoin::psbt::{bitcoin_build_unsigned_psbt, BitcoinPsbtInputFfi, BitcoinPsbtOutputFfi};
    use crate::common::CurveFfi;
    use crate::keys::MnemonicFfi;
    use crate::common::{MnemonicWordCountFfi, WordlistFfi};

    /// A syntactically valid (64 hex characters), otherwise arbitrary txid
    /// — built rather than hand-typed so its length can't be mistyped.
    fn test_txid() -> String {
        "ab".repeat(32)
    }

    fn account_descriptor(script_type: BitcoinScriptTypeFfi) -> (BitcoinDescriptorFfi, Arc<PrivateKeyFfi>) {
        let seed = MnemonicFfi::generate(MnemonicWordCountFfi::Words24, WordlistFfi::English).to_seed("".to_string());
        let master = seed.master_key(CurveFfi::Secp256k1);
        let path_string = match script_type {
            BitcoinScriptTypeFfi::P2wpkh => "m/84'/0'/0'",
            BitcoinScriptTypeFfi::P2tr => "m/86'/0'/0'",
            BitcoinScriptTypeFfi::SingleAddress => unreachable!(),
        };
        let account_key = master.derive(crate::common::DerivationPathFfi::parse(path_string).unwrap()).unwrap();
        let secp = bitcoin::secp256k1::Secp256k1::new();
        let master_secret =
            bitcoin::secp256k1::SecretKey::from_slice(&master.private_key().unwrap().raw_bytes()).unwrap();
        let master_fingerprint = {
            let master_public = bitcoin::secp256k1::PublicKey::from_secret_key(&secp, &master_secret);
            let hash = bitcoin::hashes::hash160::Hash::hash(&master_public.serialize());
            hash.as_byte_array()[0..4].to_vec()
        };

        // Build a `Xpub`-serialized string for the derived account key,
        // matching `BitcoinDescriptorFfi::from_xpub`'s expected input —
        // constructed directly from `ExtendedKeyFfi`'s own BIP-32
        // serialization (already exercised by `keys::extended_key`'s own
        // tests) rather than re-deriving through the `bitcoin` crate.
        let descriptor = BitcoinDescriptorFfi::from_xpub(
            account_key.serialized_public(),
            script_type,
            BitcoinNetworkFfi::Mainnet,
            master_fingerprint,
            path_string.trim_start_matches("m/").to_string(),
        )
        .unwrap();

        let child_key = account_key.derive(crate::common::DerivationPathFfi::parse("m/0/0").unwrap()).unwrap();
        (descriptor, child_key.private_key().unwrap())
    }

    fn funding_input(descriptor: &BitcoinDescriptorFfi, is_taproot: bool) -> BitcoinPsbtInputFfi {
        let address = descriptor.derive_address(0, 0).unwrap();
        BitcoinPsbtInputFfi {
            txid: test_txid(),
            vout: 0,
            value_sats: 100_000,
            script_pubkey: address.script_pubkey(),
            public_key: descriptor.derive_public_key(0, 0).unwrap(),
            master_fingerprint: descriptor.master_fingerprint(),
            derivation_path: format!(
                "{}/0/0",
                match descriptor.script_type() {
                    BitcoinScriptTypeFfi::P2wpkh => "84'/0'/0'",
                    BitcoinScriptTypeFfi::P2tr => "86'/0'/0'",
                    BitcoinScriptTypeFfi::SingleAddress => unreachable!(),
                }
            ),
            is_taproot,
            non_witness_utxo: None,
        }
    }

    fn output(value_sats: u64) -> BitcoinPsbtOutputFfi {
        BitcoinPsbtOutputFfi {
            script_pubkey: vec![0x00, 0x14].into_iter().chain(std::iter::repeat_n(0xcd, 20)).collect(),
            value_sats,
        }
    }

    #[test]
    fn sign_and_finalize_produce_a_valid_p2wpkh_spend() {
        let (descriptor, key) = account_descriptor(BitcoinScriptTypeFfi::P2wpkh);
        let input = funding_input(&descriptor, false);
        let unsigned = bitcoin_build_unsigned_psbt(vec![input], vec![output(90_000)], 0).unwrap();

        let signer = BitcoinSignerFfi::new();
        let signed = signer.sign_psbt(unsigned, vec![key]).unwrap();
        let raw_tx = signer.finalize_psbt(signed).unwrap();

        let tx: bitcoin::Transaction = bitcoin::consensus::encode::deserialize(&raw_tx).unwrap();
        assert_eq!(tx.input.len(), 1);
        assert_eq!(tx.input[0].witness.len(), 2, "p2wpkh witness is [signature, pubkey]");
    }

    #[test]
    fn sign_and_finalize_produce_a_valid_p2tr_key_spend() {
        let (descriptor, key) = account_descriptor(BitcoinScriptTypeFfi::P2tr);
        let input = funding_input(&descriptor, true);
        let unsigned = bitcoin_build_unsigned_psbt(vec![input], vec![output(90_000)], 0).unwrap();

        let signer = BitcoinSignerFfi::new();
        let signed = signer.sign_psbt(unsigned, vec![key]).unwrap();
        let raw_tx = signer.finalize_psbt(signed).unwrap();

        let tx: bitcoin::Transaction = bitcoin::consensus::encode::deserialize(&raw_tx).unwrap();
        assert_eq!(tx.input.len(), 1);
        assert_eq!(tx.input[0].witness.len(), 1, "p2tr key-path witness is [signature]");
    }

    #[test]
    fn sign_psbt_rejects_a_key_count_mismatch() {
        let (descriptor, key) = account_descriptor(BitcoinScriptTypeFfi::P2wpkh);
        let input = funding_input(&descriptor, false);
        let unsigned = bitcoin_build_unsigned_psbt(vec![input], vec![output(90_000)], 0).unwrap();

        let signer = BitcoinSignerFfi::new();
        assert!(matches!(
            signer.sign_psbt(unsigned, vec![key.clone(), key]),
            Err(WalletKitErrorFfi::SigningFailed { .. })
        ));
    }

    #[test]
    fn sign_psbt_rejects_a_key_that_does_not_own_the_input() {
        let (descriptor, _key) = account_descriptor(BitcoinScriptTypeFfi::P2wpkh);
        let (_other_descriptor, wrong_key) = account_descriptor(BitcoinScriptTypeFfi::P2wpkh);
        let input = funding_input(&descriptor, false);
        let unsigned = bitcoin_build_unsigned_psbt(vec![input], vec![output(90_000)], 0).unwrap();

        let signer = BitcoinSignerFfi::new();
        assert!(matches!(signer.sign_psbt(unsigned, vec![wrong_key]), Err(WalletKitErrorFfi::SigningFailed { .. })));
    }

    #[test]
    fn finalize_psbt_rejects_an_unsigned_input() {
        let (descriptor, _key) = account_descriptor(BitcoinScriptTypeFfi::P2wpkh);
        let input = funding_input(&descriptor, false);
        let unsigned = bitcoin_build_unsigned_psbt(vec![input], vec![output(90_000)], 0).unwrap();

        let signer = BitcoinSignerFfi::new();
        assert!(matches!(signer.finalize_psbt(unsigned), Err(WalletKitErrorFfi::SigningFailed { .. })));
    }
}
