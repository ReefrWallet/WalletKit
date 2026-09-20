//! `PublicKeyFfi`: a curve-tagged public key handle that can verify
//! signatures. See
//! `Walletkit/Docs/Design Specification/Keys/PublicKeyFfi.swift`.

use ed25519_dalek::{Signature as Ed25519Signature, Verifier, VerifyingKey};
use sha2::{Digest, Sha256};

use crate::common::CurveFfi;

#[derive(Debug, Clone, PartialEq, Eq, uniffi::Object)]
pub struct PublicKeyFfi {
    curve: CurveFfi,
    raw_bytes: Vec<u8>,
}

impl PublicKeyFfi {
    pub(crate) fn new(curve: CurveFfi, raw_bytes: Vec<u8>) -> PublicKeyFfi {
        PublicKeyFfi { curve, raw_bytes }
    }
}

#[uniffi::export]
impl PublicKeyFfi {
    pub fn curve(&self) -> CurveFfi {
        self.curve
    }

    /// Compressed SEC1 (33 bytes) for secp256k1, raw (32 bytes) for ed25519.
    pub fn raw_bytes(&self) -> Vec<u8> {
        self.raw_bytes.clone()
    }

    pub fn verify(&self, signature: Vec<u8>, message: Vec<u8>) -> bool {
        match self.curve {
            CurveFfi::Secp256k1 => self.verify_secp256k1(&signature, &message),
            CurveFfi::Ed25519 => self.verify_ed25519(&signature, &message),
        }
    }
}

impl PublicKeyFfi {
    fn verify_secp256k1(&self, signature: &[u8], message: &[u8]) -> bool {
        let Ok(public_key) = secp256k1::PublicKey::from_slice(&self.raw_bytes) else {
            return false;
        };
        let Ok(signature) = secp256k1::ecdsa::Signature::from_compact(signature) else {
            return false;
        };
        let digest = Sha256::digest(message);
        let message = secp256k1::Message::from_digest(digest.into());
        secp256k1::Secp256k1::verification_only()
            .verify_ecdsa(message, &signature, &public_key)
            .is_ok()
    }

    fn verify_ed25519(&self, signature: &[u8], message: &[u8]) -> bool {
        let Ok(key_bytes): Result<[u8; 32], _> = self.raw_bytes.as_slice().try_into() else {
            return false;
        };
        let Ok(verifying_key) = VerifyingKey::from_bytes(&key_bytes) else {
            return false;
        };
        let Ok(sig_bytes): Result<[u8; 64], _> = signature.try_into() else {
            return false;
        };
        verifying_key
            .verify(message, &Ed25519Signature::from_bytes(&sig_bytes))
            .is_ok()
    }
}

#[cfg(test)]
mod tests {
    use std::sync::Arc;

    use crate::common::{CurveFfi, MnemonicWordCount, Wordlist};
    use crate::keys::MnemonicFfi;

    fn master_public_key(curve: CurveFfi) -> Arc<super::PublicKeyFfi> {
        MnemonicFfi::generate(MnemonicWordCount::Words24, Wordlist::English)
            .to_seed("".to_string())
            .master_key(curve)
            .public_key()
    }

    #[test]
    fn secp256k1_raw_bytes_are_compressed_33_bytes() {
        assert_eq!(master_public_key(CurveFfi::Secp256k1).raw_bytes().len(), 33);
    }

    #[test]
    fn ed25519_raw_bytes_are_32_bytes() {
        assert_eq!(master_public_key(CurveFfi::Ed25519).raw_bytes().len(), 32);
    }

    #[test]
    fn verify_accepts_a_signature_from_the_matching_private_key() {
        let seed = MnemonicFfi::generate(MnemonicWordCount::Words24, Wordlist::English).to_seed("".to_string());
        let extended_key = seed.master_key(CurveFfi::Secp256k1);
        let message = b"hello walletkit".to_vec();
        let signature = extended_key.private_key().unwrap().sign(message.clone()).unwrap();
        assert!(extended_key.public_key().verify(signature, message));
    }

    #[test]
    fn verify_rejects_a_tampered_message() {
        let seed = MnemonicFfi::generate(MnemonicWordCount::Words24, Wordlist::English).to_seed("".to_string());
        let extended_key = seed.master_key(CurveFfi::Secp256k1);
        let signature = extended_key.private_key().unwrap().sign(b"hello".to_vec()).unwrap();
        assert!(!extended_key.public_key().verify(signature, b"goodbye".to_vec()));
    }
}
