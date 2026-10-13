//! `AptosSignerFfi`: Aptos address derivation and signing.
//!
//! Ed25519 accounts use the legacy single-key scheme; secp256k1 accounts use
//! AIP-49 `SingleKey`. Vectors in `TestVectors/aptos-*.json` come from
//! `@aptos-labs/ts-sdk`.

use std::sync::Arc;

use sha3::{Digest, Sha3_256};

use crate::blockchain_clients::aptos_address::AptosAddressFfi;
use crate::common::CurveFfi;
use crate::errors::WalletKitErrorFfi;
use crate::keys::{PrivateKeyFfi, PublicKeyFfi};

/// Authentication-key scheme byte appended before hashing.
const ED25519_SCHEME: u8 = 0x00;
const SINGLE_KEY_SCHEME: u8 = 0x02;

/// `AccountAuthenticator` variants.
const ACCOUNT_AUTH_ED25519: u8 = 0x00;
const ACCOUNT_AUTH_SINGLE_KEY: u8 = 0x02;

/// `TransactionAuthenticator::SingleSender`.
const TRANSACTION_AUTH_SINGLE_SENDER: u8 = 0x04;

/// `AnyPublicKey::Secp256k1Ecdsa` / `AnySignature::Secp256k1Ecdsa`.
const ANY_SECP256K1: u8 = 0x01;

const RAW_TRANSACTION_SALT: &[u8] = b"APTOS::RawTransaction";
const TRANSACTION_SALT: &[u8] = b"APTOS::Transaction";

/// `Transaction::UserTransaction`.
const USER_TRANSACTION: u8 = 0x00;

/// The transaction hash a node reports for BCS `SignedTransaction` bytes.
#[uniffi::export]
pub fn aptos_transaction_hash(signed_transaction: Vec<u8>) -> Vec<u8> {
    sha3_256(&[&sha3_256(&[TRANSACTION_SALT]), &[USER_TRANSACTION], &signed_transaction]).to_vec()
}

fn sha3_256(parts: &[&[u8]]) -> [u8; 32] {
    let mut hasher = Sha3_256::new();
    for part in parts {
        hasher.update(part);
    }
    hasher.finalize().into()
}

/// BCS `Vec<u8>` for lengths < 128 (single-byte ULEB128) — every key and
/// signature here is 32/64/65 bytes.
fn bcs_bytes(bytes: &[u8]) -> Vec<u8> {
    debug_assert!(bytes.len() < 0x80);
    let mut encoded = Vec::with_capacity(bytes.len() + 1);
    encoded.push(bytes.len() as u8);
    encoded.extend_from_slice(bytes);
    encoded
}

#[derive(Debug, Clone, Copy, uniffi::Object)]
pub struct AptosSignerFfi {
    curve: CurveFfi,
}

impl AptosSignerFfi {
    fn check_curve(&self, curve: CurveFfi) -> Result<(), WalletKitErrorFfi> {
        if curve != self.curve {
            return Err(WalletKitErrorFfi::UnsupportedCurve { curve });
        }
        Ok(())
    }

    /// Ed25519: raw 32 bytes. secp256k1: BCS `AnyPublicKey` over the
    /// uncompressed 65-byte key.
    fn public_key_bcs(&self, public_key: &PublicKeyFfi) -> Result<Vec<u8>, WalletKitErrorFfi> {
        match self.curve {
            CurveFfi::Ed25519 => Ok(bcs_bytes(&public_key.raw_bytes())),
            CurveFfi::Secp256k1 => {
                let key = secp256k1::PublicKey::from_slice(&public_key.raw_bytes())
                    .map_err(|err| WalletKitErrorFfi::SigningFailed { reason: err.to_string() })?;
                let mut encoded = vec![ANY_SECP256K1];
                encoded.extend(bcs_bytes(&key.serialize_uncompressed()));
                Ok(encoded)
            }
        }
    }

    /// ECDSA (secp256k1, over SHA3-256 of `message`, low-S) or EdDSA
    /// (ed25519, over `message`).
    fn raw_signature(&self, message: &[u8], private_key: &PrivateKeyFfi) -> Result<Vec<u8>, WalletKitErrorFfi> {
        match self.curve {
            CurveFfi::Ed25519 => private_key.sign(message.to_vec()),
            CurveFfi::Secp256k1 => {
                let digest = sha3_256(&[message]);
                Ok(private_key.sign_prehashed_recoverable(digest.to_vec())?.compact)
            }
        }
    }

    fn account_authenticator(&self, public_key: &PublicKeyFfi, signature: &[u8]) -> Result<Vec<u8>, WalletKitErrorFfi> {
        let mut encoded = Vec::with_capacity(140);
        match self.curve {
            CurveFfi::Ed25519 => {
                encoded.push(ACCOUNT_AUTH_ED25519);
                encoded.extend(self.public_key_bcs(public_key)?);
                encoded.extend(bcs_bytes(signature));
            }
            CurveFfi::Secp256k1 => {
                encoded.push(ACCOUNT_AUTH_SINGLE_KEY);
                encoded.extend(self.public_key_bcs(public_key)?);
                encoded.push(ANY_SECP256K1);
                encoded.extend(bcs_bytes(signature));
            }
        }
        Ok(encoded)
    }

    fn transaction_authenticator(&self, account_authenticator: Vec<u8>) -> Vec<u8> {
        match self.curve {
            // `TransactionAuthenticator::Ed25519` shares variant 0 and layout.
            CurveFfi::Ed25519 => account_authenticator,
            CurveFfi::Secp256k1 => {
                let mut encoded = vec![TRANSACTION_AUTH_SINGLE_SENDER];
                encoded.extend(account_authenticator);
                encoded
            }
        }
    }

    fn signing_message(raw_transaction: &[u8]) -> Vec<u8> {
        let mut message = sha3_256(&[RAW_TRANSACTION_SALT]).to_vec();
        message.extend_from_slice(raw_transaction);
        message
    }
}

#[uniffi::export]
impl AptosSignerFfi {
    #[uniffi::constructor]
    pub fn new(curve: CurveFfi) -> AptosSignerFfi {
        AptosSignerFfi { curve }
    }

    pub fn curve(&self) -> CurveFfi {
        self.curve
    }

    /// `SHA3-256(public key ‖ scheme)`, where the key is BCS `AnyPublicKey`
    /// for secp256k1. Throws `.unsupportedCurve` on a curve mismatch.
    pub fn address(&self, public_key: Arc<PublicKeyFfi>) -> Result<Arc<AptosAddressFfi>, WalletKitErrorFfi> {
        self.check_curve(public_key.curve())?;
        let digest = match self.curve {
            CurveFfi::Ed25519 => sha3_256(&[&public_key.raw_bytes(), &[ED25519_SCHEME]]),
            CurveFfi::Secp256k1 => sha3_256(&[&self.public_key_bcs(&public_key)?, &[SINGLE_KEY_SCHEME]]),
        };
        Ok(Arc::new(AptosAddressFfi::from_raw(digest)))
    }

    /// Signs BCS `RawTransaction` bytes, returning the BCS
    /// `TransactionAuthenticator` to append for submission.
    pub fn sign(&self, raw_transaction: Vec<u8>, private_key: Arc<PrivateKeyFfi>) -> Result<Vec<u8>, WalletKitErrorFfi> {
        let account_authenticator = self.sign_account_authenticator(raw_transaction, private_key)?;
        Ok(self.transaction_authenticator(account_authenticator))
    }

    /// Signs BCS `RawTransaction` bytes, returning the BCS
    /// `AccountAuthenticator` (what Wallet Standard `signTransaction` returns).
    pub fn sign_account_authenticator(
        &self,
        raw_transaction: Vec<u8>,
        private_key: Arc<PrivateKeyFfi>,
    ) -> Result<Vec<u8>, WalletKitErrorFfi> {
        self.check_curve(private_key.curve())?;
        let signature = self.raw_signature(&Self::signing_message(&raw_transaction), &private_key)?;
        self.account_authenticator(&private_key.public_key(), &signature)
    }

    /// Signs arbitrary message bytes, returning the raw 64-byte signature.
    pub fn sign_message(&self, message: Vec<u8>, private_key: Arc<PrivateKeyFfi>) -> Result<Vec<u8>, WalletKitErrorFfi> {
        self.check_curve(private_key.curve())?;
        self.raw_signature(&message, &private_key)
    }

    /// `TransactionAuthenticator` with an all-zero signature, for
    /// `/transactions/simulate`.
    pub fn simulation_authenticator(&self, public_key: Arc<PublicKeyFfi>) -> Result<Vec<u8>, WalletKitErrorFfi> {
        self.check_curve(public_key.curve())?;
        let account_authenticator = self.account_authenticator(&public_key, &[0u8; 64])?;
        Ok(self.transaction_authenticator(account_authenticator))
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::Value;

    fn vectors(name: &str) -> Vec<Value> {
        let raw = match name {
            "address" => include_str!("../../../../../TestVectors/aptos-address.json"),
            "derivation" => include_str!("../../../../../TestVectors/aptos-derivation.json"),
            "message" => include_str!("../../../../../TestVectors/aptos-message.json"),
            "tx" => include_str!("../../../../../TestVectors/aptos-tx.json"),
            _ => unreachable!(),
        };
        serde_json::from_str::<Value>(raw).unwrap().as_array().unwrap().clone()
    }

    fn bytes(entry: &Value, key: &str) -> Vec<u8> {
        hex::decode(entry[key].as_str().unwrap().trim_start_matches("0x")).unwrap()
    }

    fn curve(entry: &Value) -> CurveFfi {
        match entry["scheme"].as_str().unwrap() {
            "ed25519" => CurveFfi::Ed25519,
            "secp256k1" => CurveFfi::Secp256k1,
            other => panic!("unexpected scheme {other}"),
        }
    }

    fn private_key(entry: &Value) -> Arc<PrivateKeyFfi> {
        let raw: [u8; 32] = bytes(entry, "privateKey").try_into().unwrap();
        Arc::new(PrivateKeyFfi::new(curve(entry), raw))
    }

    #[test]
    fn address_matches_ts_sdk() {
        for entry in vectors("address") {
            let key = private_key(&entry);
            let address = AptosSignerFfi::new(curve(&entry)).address(key.public_key()).unwrap();
            assert_eq!(address.string_long(), entry["address"].as_str().unwrap(), "{}", entry["label"]);
        }
    }

    #[test]
    fn secp256k1_any_public_key_matches_ts_sdk() {
        for entry in vectors("address").iter().filter(|entry| curve(entry) == CurveFfi::Secp256k1) {
            let signer = AptosSignerFfi::new(CurveFfi::Secp256k1);
            let encoded = signer.public_key_bcs(&private_key(entry).public_key()).unwrap();
            assert_eq!(encoded, bytes(entry, "anyPublicKeyBcsHex"), "{}", entry["label"]);
            assert_eq!(encoded[2..], bytes(entry, "publicKey")[..], "{}", entry["label"]);
        }
    }

    #[test]
    fn derived_addresses_match_ts_sdk() {
        use crate::common::{DerivationPathFfi, WordlistFfi};
        use crate::keys::MnemonicFfi;

        for entry in vectors("derivation") {
            let mnemonic = MnemonicFfi::from_phrase(entry["mnemonic"].as_str().unwrap().to_string(), WordlistFfi::English)
                .unwrap();
            let path = DerivationPathFfi::parse(entry["path"].as_str().unwrap()).unwrap();
            let key = mnemonic.to_seed(String::new()).master_key(curve(&entry)).derive(path).unwrap().private_key().unwrap();
            let address = AptosSignerFfi::new(curve(&entry)).address(key.public_key()).unwrap();
            assert_eq!(address.string_long(), entry["address"].as_str().unwrap(), "{}", entry["path"]);
        }
    }

    #[test]
    fn signing_message_matches_ts_sdk() {
        for entry in vectors("tx") {
            let message = AptosSignerFfi::signing_message(&bytes(&entry, "rawTransactionBcsHex"));
            assert_eq!(message, bytes(&entry, "signingMessageHex"), "{}", entry["label"]);
        }
    }

    #[test]
    fn transaction_signatures_match_ts_sdk() {
        for entry in vectors("tx") {
            let signer = AptosSignerFfi::new(curve(&entry));
            let raw = bytes(&entry, "rawTransactionBcsHex");
            let account = signer.sign_account_authenticator(raw.clone(), private_key(&entry)).unwrap();
            assert_eq!(account, bytes(&entry, "accountAuthenticatorBcsHex"), "{}", entry["label"]);

            let mut signed = raw.clone();
            signed.extend(signer.sign(raw, private_key(&entry)).unwrap());
            assert_eq!(signed, bytes(&entry, "signedTransactionBcsHex"), "{}", entry["label"]);
        }
    }

    #[test]
    fn transaction_hashes_match_ts_sdk() {
        for entry in vectors("tx") {
            let hash = aptos_transaction_hash(bytes(&entry, "signedTransactionBcsHex"));
            assert_eq!(hash, bytes(&entry, "transactionHashHex"), "{}", entry["label"]);
        }
    }

    #[test]
    fn message_signatures_match_ts_sdk() {
        for entry in vectors("message") {
            let signer = AptosSignerFfi::new(curve(&entry));
            let signature = signer.sign_message(bytes(&entry, "messageHex"), private_key(&entry)).unwrap();
            assert_eq!(signature, bytes(&entry, "signatureHex"), "{}", entry["label"]);
        }
    }

    #[test]
    fn simulation_authenticator_matches_signed_layout() {
        for entry in vectors("tx") {
            let signer = AptosSignerFfi::new(curve(&entry));
            let key = private_key(&entry);
            let real = signer.sign(bytes(&entry, "rawTransactionBcsHex"), key.clone()).unwrap();
            let simulated = signer.simulation_authenticator(key.public_key()).unwrap();
            assert_eq!(real.len(), simulated.len(), "{}", entry["label"]);
            assert_eq!(&simulated[simulated.len() - 64..], &[0u8; 64], "{}", entry["label"]);
            assert_eq!(&real[..real.len() - 64], &simulated[..simulated.len() - 64], "{}", entry["label"]);
        }
    }

    #[test]
    fn rejects_a_curve_mismatch() {
        let entry = vectors("address").into_iter().find(|entry| curve(entry) == CurveFfi::Ed25519).unwrap();
        let signer = AptosSignerFfi::new(CurveFfi::Secp256k1);
        let key = private_key(&entry);
        assert!(matches!(signer.address(key.public_key()), Err(WalletKitErrorFfi::UnsupportedCurve { .. })));
        assert!(matches!(signer.sign(vec![0], key.clone()), Err(WalletKitErrorFfi::UnsupportedCurve { .. })));
        assert!(matches!(signer.sign_message(vec![0], key), Err(WalletKitErrorFfi::UnsupportedCurve { .. })));
    }

    #[test]
    fn same_key_bytes_give_different_addresses_per_curve() {
        let raw = [0x33u8; 32];
        let ed = Arc::new(PrivateKeyFfi::new(CurveFfi::Ed25519, raw));
        let k1 = Arc::new(PrivateKeyFfi::new(CurveFfi::Secp256k1, raw));
        let ed_address = AptosSignerFfi::new(CurveFfi::Ed25519).address(ed.public_key()).unwrap();
        let k1_address = AptosSignerFfi::new(CurveFfi::Secp256k1).address(k1.public_key()).unwrap();
        assert_ne!(ed_address.raw_bytes(), k1_address.raw_bytes());
    }
}
