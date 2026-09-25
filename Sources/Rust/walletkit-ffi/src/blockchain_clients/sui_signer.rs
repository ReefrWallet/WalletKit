//! `SuiSignerFfi`: address derivation for Sui, backed by RustCrypto's
//! `blake2` crate for Sui's Blake2b-256 flag-tagged address scheme. See
//! `Walletkit/Docs/Design Specification/Clients/Sui/SuiSigner.swift`.

use std::sync::Arc;

use blake2::digest::{Update, VariableOutput};
use blake2::Blake2bVar;

use crate::blockchain_clients::sui_address::SuiAddressFfi;
use crate::common::CurveFfi;
use crate::errors::WalletKitErrorFfi;
use crate::keys::{PrivateKeyFfi, PublicKeyFfi};

/// Sui's 3-byte "intent" prefix for a `TransactionData` being signed:
/// scope `0` (`TransactionData`), version `0` (`V0`), app id `0` (`Sui`).
/// Sui wraps every signable payload in this scope/version/app-id triple so
/// signatures over different message kinds (transactions, personal
/// messages, consensus messages, ...) can never be replayed against each
/// other.
const TRANSACTION_DATA_INTENT: [u8; 3] = [0, 0, 0];

/// Scheme flag Sui prefixes a public key with before hashing — `0x00` for
/// Ed25519, `0x01` for Secp256k1. (Sui defines further flags for schemes
/// this crate doesn't support, e.g. Secp256r1/multisig.)
fn scheme_flag(curve: CurveFfi) -> u8 {
    match curve {
        CurveFfi::Ed25519 => 0x00,
        CurveFfi::Secp256k1 => 0x01,
    }
}

/// Blake2b-256 over the concatenation of `parts`, fed to the hasher in
/// order without actually concatenating them into one buffer first.
fn blake2b_256(parts: &[&[u8]]) -> [u8; 32] {
    let mut hasher = Blake2bVar::new(32).expect("32 is a valid Blake2b-var output size");
    for part in parts {
        hasher.update(part);
    }
    let mut digest = [0u8; 32];
    hasher.finalize_variable(&mut digest).expect("digest buffer is exactly the requested 32 bytes");
    digest
}

/// Which signature scheme this signer's accounts use — the `CurveFfi`
/// carried by `Blockchain.sui(_:)`.
#[derive(Debug, Clone, Copy, uniffi::Object)]
pub struct SuiSignerFfi {
    curve: CurveFfi,
}

#[uniffi::export]
impl SuiSignerFfi {
    #[uniffi::constructor]
    pub fn new(curve: CurveFfi) -> SuiSignerFfi {
        SuiSignerFfi { curve }
    }

    pub fn curve(&self) -> CurveFfi {
        self.curve
    }

    /// Derives the `SuiAddressFfi` for `public_key`: Blake2b-256 hash of a
    /// one-byte scheme flag (see `scheme_flag`) followed by `public_key`'s
    /// raw bytes (32-byte raw Ed25519, or 33-byte compressed secp256k1) —
    /// the full 32-byte digest is the address, with no truncation.
    ///
    /// Throws `.unsupportedCurve` if `public_key.curve() != self.curve` —
    /// an account derived for one scheme can't produce an address tagged
    /// with a different one, since `self.curve` is what selects the flag
    /// byte.
    pub fn address(&self, public_key: Arc<PublicKeyFfi>) -> Result<Arc<SuiAddressFfi>, WalletKitErrorFfi> {
        if public_key.curve() != self.curve {
            return Err(WalletKitErrorFfi::UnsupportedCurve { curve: public_key.curve() });
        }

        let digest = blake2b_256(&[&[scheme_flag(self.curve)], &public_key.raw_bytes()]);
        Ok(Arc::new(SuiAddressFfi::from_raw(digest)))
    }

    /// Signs `transaction_data` — raw, un-intent-prefixed BCS-encoded
    /// `TransactionData` bytes, e.g. from `sui client ptb
    /// --serialize-unsigned-transaction` — with `private_key`, returning
    /// Sui's serialized signature (`flag || signature || public_key`)
    /// ready to broadcast alongside `transaction_data`.
    ///
    /// Algorithm: prepend the 3-byte `TRANSACTION_DATA_INTENT` to
    /// `transaction_data`, Blake2b-256 hash the result, and sign that
    /// 32-byte digest with `private_key`. `PrivateKeyFfi::sign` already
    /// implements exactly the hash-then-sign Sui expects for both
    /// supported curves: ed25519 signs the digest bytes directly (EdDSA
    /// hashes internally), and secp256k1 SHA-256-hashes the digest before
    /// ECDSA — matching fastcrypto's default secp256k1 signing behavior
    /// bit-for-bit (cross-checked against `sui keytool sign`'s own output;
    /// see `TestVectors/sui-tx.json`).
    ///
    /// Throws `.unsupportedCurve` if `private_key.curve() != self.curve`.
    pub fn sign(
        &self,
        transaction_data: Vec<u8>,
        private_key: Arc<PrivateKeyFfi>,
    ) -> Result<Vec<u8>, WalletKitErrorFfi> {
        if private_key.curve() != self.curve {
            return Err(WalletKitErrorFfi::UnsupportedCurve { curve: private_key.curve() });
        }

        let digest = blake2b_256(&[&TRANSACTION_DATA_INTENT, &transaction_data]);

        let signature = private_key.sign(digest.to_vec())?;
        let public_key = private_key.public_key();

        let mut serialized = Vec::with_capacity(1 + signature.len() + public_key.raw_bytes().len());
        serialized.push(scheme_flag(self.curve));
        serialized.extend_from_slice(&signature);
        serialized.extend_from_slice(&public_key.raw_bytes());
        Ok(serialized)
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::common::{MnemonicWordCount, Wordlist};
    use crate::keys::{MnemonicFfi, PrivateKeyFfi};

    fn public_key(curve: CurveFfi) -> Arc<PublicKeyFfi> {
        MnemonicFfi::generate(MnemonicWordCount::Words24, Wordlist::English)
            .to_seed("".to_string())
            .master_key(curve)
            .public_key()
    }

    struct Vector {
        label: String,
        /// `None` for schemes `CurveFfi` doesn't have a case for yet (Sui's
        /// secp256r1) — those vectors carry no private key exercise, only
        /// a public key/address pair (see `secp256r1_vectors...` below).
        curve: Option<CurveFfi>,
        private_key: Vec<u8>,
        public_key: Vec<u8>,
        address: String,
    }

    /// Generated with the official `sui keytool generate <scheme> --json`
    /// (Sui CLI 1.66.2) — see `TestVectors/sui-address.json` for how each
    /// entry's `privateKey` was recovered from the tool's output.
    fn vectors() -> Vec<Vector> {
        let raw = include_str!("../../../../../TestVectors/sui-address.json");
        let json: serde_json::Value = serde_json::from_str(raw).expect("sui-address.json is valid JSON");
        json.as_array()
            .expect("sui-address.json is a JSON array")
            .iter()
            .map(|entry| {
                let curve = match entry["scheme"].as_str().unwrap() {
                    "ed25519" => Some(CurveFfi::Ed25519),
                    "secp256k1" => Some(CurveFfi::Secp256k1),
                    "secp256r1" => None,
                    other => panic!("unexpected scheme {other} in sui-address.json"),
                };
                Vector {
                    label: entry["label"].as_str().unwrap().to_string(),
                    curve,
                    private_key: hex::decode(entry["privateKey"].as_str().unwrap().trim_start_matches("0x"))
                        .unwrap(),
                    public_key: hex::decode(entry["publicKey"].as_str().unwrap().trim_start_matches("0x"))
                        .unwrap(),
                    address: entry["address"].as_str().unwrap().to_string(),
                }
            })
            .collect()
    }

    #[test]
    fn address_matches_every_sui_keytool_vectors_expected_address() {
        for vector in vectors() {
            // secp256r1 vectors are covered by
            // `secp256r1_vectors_match_the_flag_tagged_address_formula`
            // instead — `CurveFfi` has no case for that scheme yet, so there's
            // no `PrivateKeyFfi`/`SuiSignerFfi` to drive through here.
            let Some(curve) = vector.curve else { continue };

            let private_key: [u8; 32] = vector
                .private_key
                .as_slice()
                .try_into()
                .unwrap_or_else(|_| panic!("{}: private key is not 32 bytes", vector.label));
            let private_key = Arc::new(PrivateKeyFfi::new(curve, private_key));

            let public_key = private_key.public_key();
            assert_eq!(public_key.raw_bytes(), vector.public_key, "{}: derived public key mismatch", vector.label);

            let signer = SuiSignerFfi::new(curve);
            let address = signer.address(public_key).unwrap_or_else(|err| panic!("{}: {err}", vector.label));
            assert_eq!(address.string(), vector.address, "{}", vector.label);
        }
    }

    #[test]
    fn secp256r1_vectors_match_the_flag_tagged_address_formula() {
        // `CurveFfi`/`PrivateKeyFfi` don't support secp256r1 (Sui's third
        // scheme) yet, so this can't derive the public key from the
        // vector's private key the way the ed25519/secp256k1 case above
        // does. It still checks the part that doesn't need curve support:
        // that Sui's official address for a secp256r1 key really is
        // `Blake2b-256(0x02 || publicKey)`, using the public key
        // `sui keytool` reported directly.
        const SECP256R1_FLAG: u8 = 0x02;
        let mut checked = 0;
        for vector in vectors() {
            if vector.curve.is_some() {
                continue;
            }
            let digest = blake2b_256(&[&[SECP256R1_FLAG], &vector.public_key]);
            assert_eq!(
                SuiAddressFfi::from_raw(digest).string(),
                vector.address,
                "{}",
                vector.label
            );
            checked += 1;
        }
        assert!(checked > 0, "expected at least one secp256r1 vector in sui-address.json");
    }

    #[test]
    fn address_matches_independently_computed_blake2b_hash_for_ed25519() {
        let signer = SuiSignerFfi::new(CurveFfi::Ed25519);
        let key = public_key(CurveFfi::Ed25519);
        let address = signer.address(key.clone()).unwrap();
        assert_eq!(address.raw_bytes(), blake2b_256(&[&[0x00], &key.raw_bytes()]));
    }

    #[test]
    fn address_matches_independently_computed_blake2b_hash_for_secp256k1() {
        let signer = SuiSignerFfi::new(CurveFfi::Secp256k1);
        let key = public_key(CurveFfi::Secp256k1);
        let address = signer.address(key.clone()).unwrap();
        assert_eq!(address.raw_bytes(), blake2b_256(&[&[0x01], &key.raw_bytes()]));
    }

    #[test]
    fn address_is_32_bytes() {
        let signer = SuiSignerFfi::new(CurveFfi::Ed25519);
        let key = public_key(CurveFfi::Ed25519);
        assert_eq!(signer.address(key).unwrap().raw_bytes().len(), 32);
    }

    #[test]
    fn address_rejects_a_curve_mismatch() {
        let signer = SuiSignerFfi::new(CurveFfi::Ed25519);
        let key = public_key(CurveFfi::Secp256k1);
        assert!(matches!(
            signer.address(key),
            Err(WalletKitErrorFfi::UnsupportedCurve { curve: CurveFfi::Secp256k1 })
        ));
    }

    #[test]
    fn different_schemes_produce_different_addresses_for_the_same_key_bytes() {
        // Same raw key bytes, hashed with each scheme's own flag byte, must
        // diverge — the flag is what lets Sui tell the schemes apart.
        let key_bytes = vec![7u8; 32];
        let ed25519_address = blake2b_256(&[&[scheme_flag(CurveFfi::Ed25519)], &key_bytes]);
        let secp256k1_address = blake2b_256(&[&[scheme_flag(CurveFfi::Secp256k1)], &key_bytes]);
        assert_ne!(ed25519_address, secp256k1_address);
    }

    #[test]
    fn curve_returns_the_configured_scheme() {
        assert_eq!(SuiSignerFfi::new(CurveFfi::Secp256k1).curve(), CurveFfi::Secp256k1);
    }

    struct TxVector {
        label: String,
        /// `None` for secp256r1 — see `Vector::curve` above, same reason.
        curve: Option<CurveFfi>,
        private_key: Vec<u8>,
        transaction_data: Vec<u8>,
        signature: Vec<u8>,
    }

    /// Generated from real Programmable Transaction Blocks built with `sui
    /// client ptb ... --serialize-unsigned-transaction` against a local
    /// `sui start` test validator (so gas object references are real, not
    /// fabricated), signed with `sui keytool sign`, and independently
    /// confirmed with both `sui keytool decode-or-verify-tx` and `sui
    /// client execute-signed-tx` — see `TestVectors/sui-tx.json`.
    fn tx_vectors() -> Vec<TxVector> {
        let raw = include_str!("../../../../../TestVectors/sui-tx.json");
        let json: serde_json::Value = serde_json::from_str(raw).expect("sui-tx.json is valid JSON");
        json.as_array()
            .expect("sui-tx.json is a JSON array")
            .iter()
            .map(|entry| {
                let curve = match entry["scheme"].as_str().unwrap() {
                    "ed25519" => Some(CurveFfi::Ed25519),
                    "secp256k1" => Some(CurveFfi::Secp256k1),
                    "secp256r1" => None,
                    other => panic!("unexpected scheme {other} in sui-tx.json"),
                };
                TxVector {
                    label: entry["label"].as_str().unwrap().to_string(),
                    curve,
                    private_key: hex::decode(entry["privateKey"].as_str().unwrap().trim_start_matches("0x"))
                        .unwrap(),
                    transaction_data: hex::decode(
                        entry["transactionDataBcsHex"].as_str().unwrap().trim_start_matches("0x"),
                    )
                    .unwrap(),
                    signature: hex::decode(entry["signatureHex"].as_str().unwrap().trim_start_matches("0x"))
                        .unwrap(),
                }
            })
            .collect()
    }

    #[test]
    fn sign_matches_every_vectors_expected_signature() {
        for vector in tx_vectors() {
            // secp256r1 vectors can't be driven through `PrivateKeyFfi`/
            // `SuiSignerFfi` — `CurveFfi` has no case for that scheme yet.
            let Some(curve) = vector.curve else { continue };

            let private_key: [u8; 32] = vector
                .private_key
                .as_slice()
                .try_into()
                .unwrap_or_else(|_| panic!("{}: private key is not 32 bytes", vector.label));
            let private_key = Arc::new(PrivateKeyFfi::new(curve, private_key));

            let signer = SuiSignerFfi::new(curve);
            let signature = signer
                .sign(vector.transaction_data.clone(), private_key)
                .unwrap_or_else(|err| panic!("{}: {err}", vector.label));
            assert_eq!(signature, vector.signature, "{}", vector.label);
        }
    }

    #[test]
    fn secp256r1_vector_is_present_for_when_curve_support_lands() {
        // Mirrors `secp256r1_vectors_match_the_flag_tagged_address_formula`
        // above: there's no P-256 dependency in this crate to verify an
        // ECDSA/secp256r1 signature with, so this just confirms the vector
        // (and its `scheme` field) is there, ready for
        // `sign_matches_every_vectors_expected_signature` to pick up once
        // `CurveFfi` grows a `Secp256r1` case.
        assert!(tx_vectors().iter().any(|vector| vector.curve.is_none()));
    }

    #[test]
    fn sign_rejects_a_curve_mismatch() {
        let vector = tx_vectors().into_iter().find(|vector| vector.curve == Some(CurveFfi::Ed25519)).unwrap();
        let private_key: [u8; 32] = vector.private_key.as_slice().try_into().unwrap();
        let private_key = Arc::new(PrivateKeyFfi::new(CurveFfi::Ed25519, private_key));

        let signer = SuiSignerFfi::new(CurveFfi::Secp256k1);
        assert!(matches!(
            signer.sign(vector.transaction_data, private_key),
            Err(WalletKitErrorFfi::UnsupportedCurve { curve: CurveFfi::Ed25519 })
        ));
    }

    #[test]
    fn sign_produces_flag_signature_public_key_of_the_expected_lengths() {
        let signer = SuiSignerFfi::new(CurveFfi::Ed25519);
        let private_key = master_private_key(CurveFfi::Ed25519);
        let signature = signer.sign(vec![0xc0], private_key).unwrap();
        // flag (1) + ed25519 signature (64) + ed25519 public key (32).
        assert_eq!(signature.len(), 1 + 64 + 32);
        assert_eq!(signature[0], 0x00);
    }

    fn master_private_key(curve: CurveFfi) -> Arc<PrivateKeyFfi> {
        MnemonicFfi::generate(MnemonicWordCount::Words24, Wordlist::English)
            .to_seed("".to_string())
            .master_key(curve)
            .private_key()
            .unwrap()
    }
}
