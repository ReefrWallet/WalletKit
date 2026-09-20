//! `PrivateKeyFfi`: a curve-tagged private key handle. No raw-bytes getter by
//! design — see
//! `Walletkit/Docs/Design Specification/Keys/PrivateKeyFfi.swift`.

use ed25519_dalek::Signer;
use sha2::{Digest, Sha256};
use std::sync::Arc;
use zeroize::Zeroizing;

use crate::common::CurveFfi;
use crate::errors::WalletKitErrorFfi;
use crate::keys::public_key::PublicKeyFfi;

#[derive(uniffi::Object)]
pub struct PrivateKeyFfi {
    curve: CurveFfi,
    raw_bytes: Zeroizing<[u8; 32]>,
}

impl std::fmt::Debug for PrivateKeyFfi {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("PrivateKeyFfi").finish_non_exhaustive()
    }
}

impl PrivateKeyFfi {
    pub(crate) fn new(curve: CurveFfi, raw_bytes: [u8; 32]) -> PrivateKeyFfi {
        PrivateKeyFfi {
            curve,
            raw_bytes: Zeroizing::new(raw_bytes),
        }
    }

    /// Raw secret scalar bytes — crate-private. Not `#[uniffi::export]`ed:
    /// `PrivateKeyFfi` deliberately has no raw-bytes getter on its exported
    /// FFI surface (see module docs). `blockchain_clients::bitcoin::signer`
    /// needs the scalar itself to perform BIP-341's taproot key tweak
    /// (`secret + tagged_hash(...)`) via `bitcoin::key::TapTweak`, which
    /// operates below the level of any signing primitive this type already
    /// exposes — this accessor stays internal to the crate.
    pub(crate) fn raw_bytes(&self) -> [u8; 32] {
        *self.raw_bytes
    }
}

#[uniffi::export]
impl PrivateKeyFfi {
    /// Imports a private key directly from raw bytes — e.g. an externally
    /// held key, a hardware backup, or (in tests) a shared test vector —
    /// bypassing mnemonic/BIP32 derivation entirely. This is the only way
    /// to construct a `PrivateKeyFfi` from outside this crate; the derived
    /// path (`ExtendedKeyFfi::private_key`) is otherwise the only source.
    ///
    /// Throws `.signingFailed` if `raw_bytes.len() != 32`, or (secp256k1
    /// only) if the 32 bytes aren't a valid scalar in the curve's order.
    #[uniffi::constructor]
    pub fn from_raw_bytes(curve: CurveFfi, raw_bytes: Vec<u8>) -> Result<PrivateKeyFfi, WalletKitErrorFfi> {
        let array: [u8; 32] = raw_bytes.as_slice().try_into().map_err(|_| WalletKitErrorFfi::SigningFailed {
            reason: format!("expected a 32-byte private key, got {} bytes", raw_bytes.len()),
        })?;
        if curve == CurveFfi::Secp256k1 {
            secp256k1::SecretKey::from_byte_array(array)
                .map_err(|err| WalletKitErrorFfi::SigningFailed { reason: err.to_string() })?;
        }
        Ok(PrivateKeyFfi::new(curve, array))
    }

    pub fn curve(&self) -> CurveFfi {
        self.curve
    }

    pub fn public_key(&self) -> Arc<PublicKeyFfi> {
        let public_key = match self.curve {
            CurveFfi::Secp256k1 => {
                let secp = secp256k1::Secp256k1::signing_only();
                let secret = secp256k1::SecretKey::from_byte_array(*self.raw_bytes)
                    .expect("derived secp256k1 private keys are always valid scalars");
                let public = secp256k1::PublicKey::from_secret_key(&secp, &secret);
                PublicKeyFfi::new(CurveFfi::Secp256k1, public.serialize().to_vec())
            }
            CurveFfi::Ed25519 => {
                let signing_key = ed25519_dalek::SigningKey::from_bytes(&self.raw_bytes);
                PublicKeyFfi::new(CurveFfi::Ed25519, signing_key.verifying_key().to_bytes().to_vec())
            }
        };
        Arc::new(public_key)
    }

    /// Deterministic ECDSA (secp256k1, over the SHA-256 digest) or EdDSA
    /// (ed25519, over the raw message).
    pub fn sign(&self, message: Vec<u8>) -> Result<Vec<u8>, WalletKitErrorFfi> {
        match self.curve {
            CurveFfi::Secp256k1 => {
                let secp = secp256k1::Secp256k1::signing_only();
                let secret = secp256k1::SecretKey::from_byte_array(*self.raw_bytes)
                    .map_err(|err| WalletKitErrorFfi::SigningFailed { reason: err.to_string() })?;
                let digest = Sha256::digest(&message);
                let message = secp256k1::Message::from_digest(digest.into());
                Ok(secp.sign_ecdsa(message, &secret).serialize_compact().to_vec())
            }
            CurveFfi::Ed25519 => {
                let signing_key = ed25519_dalek::SigningKey::from_bytes(&self.raw_bytes);
                Ok(signing_key.sign(&message).to_bytes().to_vec())
            }
        }
    }

    /// Recoverable secp256k1 ECDSA signature over an already-hashed 32-byte
    /// digest — unlike `sign()` above, which always hashes with SHA-256
    /// itself, `digest` is used as-is (e.g. a Keccak-256 digest, for
    /// Ethereum). Returns the compact `(r, s)` signature plus a 0/1
    /// recovery id, which is what Ethereum-style transaction signing (`v`)
    /// needs on top of a plain signature.
    ///
    /// Throws `.unsupportedCurve` for ed25519 keys — recoverable signing is
    /// a secp256k1-specific concept; ed25519 verification never needs
    /// public-key recovery.
    pub fn sign_prehashed_recoverable(
        &self,
        digest: Vec<u8>,
    ) -> Result<RecoverableSignatureFfi, WalletKitErrorFfi> {
        if self.curve != CurveFfi::Secp256k1 {
            return Err(WalletKitErrorFfi::UnsupportedCurve { curve: self.curve });
        }
        let digest_array: [u8; 32] = digest.as_slice().try_into().map_err(|_| WalletKitErrorFfi::SigningFailed {
            reason: format!("expected a 32-byte digest, got {} bytes", digest.len()),
        })?;
        let secp = secp256k1::Secp256k1::signing_only();
        let secret = secp256k1::SecretKey::from_byte_array(*self.raw_bytes)
            .map_err(|err| WalletKitErrorFfi::SigningFailed { reason: err.to_string() })?;
        let message = secp256k1::Message::from_digest(digest_array);
        let signature = secp.sign_ecdsa_recoverable(message, &secret);
        let (recovery_id, compact) = signature.serialize_compact();
        Ok(RecoverableSignatureFfi {
            compact: compact.to_vec(),
            recovery_id: i32::from(recovery_id) as u8,
        })
    }
}

/// `(r, s)` compact signature plus a 0/1 recovery id — the pieces
/// `blockchain_clients::ethereum` needs to build an EIP-155 `v` value.
/// A dedicated record (rather than a raw tuple) since UniFFI's exported
/// function signatures don't support Rust tuples directly.
#[derive(Debug, Clone, uniffi::Record)]
pub struct RecoverableSignatureFfi {
    pub compact: Vec<u8>,
    pub recovery_id: u8,
}

#[cfg(test)]
mod tests {
    use crate::common::{CurveFfi, MnemonicWordCount, Wordlist};
    use crate::keys::MnemonicFfi;

    fn master_private_key(curve: CurveFfi) -> std::sync::Arc<super::PrivateKeyFfi> {
        MnemonicFfi::generate(MnemonicWordCount::Words24, Wordlist::English)
            .to_seed("".to_string())
            .master_key(curve)
            .private_key()
            .unwrap()
    }

    #[test]
    fn from_raw_bytes_produces_a_key_matching_its_own_derived_public_key() {
        // A fixed, valid secp256k1 scalar — arbitrary, not derived from any
        // mnemonic.
        let raw_bytes = [7u8; 32];
        let imported = super::PrivateKeyFfi::from_raw_bytes(CurveFfi::Secp256k1, raw_bytes.to_vec()).unwrap();

        // Independently compute the expected public key straight from the
        // secp256k1 crate, without going through `PrivateKeyFfi` (which has
        // no raw-bytes getter by design, so it can't be used both to build
        // and to verify the same round trip).
        let secp = secp256k1::Secp256k1::signing_only();
        let secret = secp256k1::SecretKey::from_byte_array(raw_bytes).unwrap();
        let expected_public = secp256k1::PublicKey::from_secret_key(&secp, &secret);

        assert_eq!(imported.public_key().raw_bytes(), expected_public.serialize().to_vec());
    }

    #[test]
    fn from_raw_bytes_rejects_the_wrong_byte_count() {
        assert!(matches!(
            super::PrivateKeyFfi::from_raw_bytes(CurveFfi::Secp256k1, vec![0u8; 31]),
            Err(crate::errors::WalletKitErrorFfi::SigningFailed { .. })
        ));
    }

    #[test]
    fn from_raw_bytes_rejects_a_secp256k1_scalar_out_of_range() {
        // All-0xff is larger than the secp256k1 curve order, so it isn't a
        // valid private key scalar.
        assert!(matches!(
            super::PrivateKeyFfi::from_raw_bytes(CurveFfi::Secp256k1, vec![0xffu8; 32]),
            Err(crate::errors::WalletKitErrorFfi::SigningFailed { .. })
        ));
    }

    #[test]
    fn from_raw_bytes_accepts_any_32_bytes_for_ed25519() {
        // Unlike secp256k1, ed25519 has no scalar-validity constraint on the
        // raw seed bytes.
        assert!(super::PrivateKeyFfi::from_raw_bytes(CurveFfi::Ed25519, vec![0xffu8; 32]).is_ok());
    }

    #[test]
    fn public_key_matches_the_deriving_extended_keys_public_key() {
        let seed = MnemonicFfi::generate(MnemonicWordCount::Words24, Wordlist::English).to_seed("".to_string());
        let extended_key = seed.master_key(CurveFfi::Secp256k1);
        let private_key = extended_key.private_key().unwrap();
        assert_eq!(private_key.public_key().raw_bytes(), extended_key.public_key().raw_bytes());
    }

    #[test]
    fn sign_produces_a_signature_verifiable_by_its_own_public_key() {
        let private_key = master_private_key(CurveFfi::Secp256k1);
        let message = b"sign me".to_vec();
        let signature = private_key.sign(message.clone()).unwrap();
        assert!(private_key.public_key().verify(signature, message));
    }

    #[test]
    fn curve_matches_the_deriving_extended_keys_curve() {
        let private_key = master_private_key(CurveFfi::Ed25519);
        assert_eq!(private_key.curve(), CurveFfi::Ed25519);
    }
}
