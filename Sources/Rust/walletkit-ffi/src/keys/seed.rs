//! `SeedFfi`: a 64-byte BIP39 seed, and the entry point for master-key
//! derivation. See `Walletkit/Docs/Design Specification/Keys/SeedFfi.swift`.

use std::sync::Arc;

use zeroize::Zeroizing;

use crate::common::CurveFfi;
use crate::errors::WalletKitErrorFfi;
use crate::keys::extended_key::ExtendedKeyFfi;

#[derive(uniffi::Object)]
pub struct SeedFfi {
    raw_bytes: Zeroizing<[u8; 64]>,
}

impl std::fmt::Debug for SeedFfi {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("SeedFfi").finish_non_exhaustive()
    }
}

impl SeedFfi {
    pub(crate) fn new(raw_bytes: [u8; 64]) -> SeedFfi {
        SeedFfi {
            raw_bytes: Zeroizing::new(raw_bytes),
        }
    }
}

#[uniffi::export]
impl SeedFfi {
    /// Reconstructs a `SeedFfi` from previously exported raw bytes (see
    /// `export_raw`) — e.g. seed material persisted outside the process
    /// that generated it. Throws `.invalidSeed` if `raw_bytes.len() != 64`.
    #[uniffi::constructor]
    pub fn from_raw_bytes(raw_bytes: Vec<u8>) -> Result<SeedFfi, WalletKitErrorFfi> {
        let array: [u8; 64] = raw_bytes.as_slice().try_into().map_err(|_| WalletKitErrorFfi::InvalidSeed {
            reason: format!("expected a 64-byte seed, got {} bytes", raw_bytes.len()),
        })?;
        Ok(SeedFfi::new(array))
    }

    /// Derives the master `ExtendedKeyFfi` for the requested curve/scheme.
    pub fn master_key(&self, curve: CurveFfi) -> Arc<ExtendedKeyFfi> {
        Arc::new(ExtendedKeyFfi::master(curve, self.raw_bytes.as_slice()))
    }

    /// Raw 64-byte seed. Sensitive — treat as short-lived, don't log it.
    pub fn export_raw(&self) -> Vec<u8> {
        self.raw_bytes.to_vec()
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::common::{MnemonicWordCountFfi, WordlistFfi};
    use crate::keys::MnemonicFfi;

    fn seed() -> Arc<SeedFfi> {
        MnemonicFfi::generate(MnemonicWordCountFfi::Words24, WordlistFfi::English).to_seed("".to_string())
    }

    #[test]
    fn export_raw_produces_64_bytes() {
        assert_eq!(seed().export_raw().len(), 64);
    }

    #[test]
    fn master_key_supports_secp256k1() {
        let key = seed().master_key(CurveFfi::Secp256k1);
        assert_eq!(key.curve(), CurveFfi::Secp256k1);
        assert_eq!(key.depth(), 0);
    }

    #[test]
    fn master_key_supports_ed25519() {
        let key = seed().master_key(CurveFfi::Ed25519);
        assert_eq!(key.curve(), CurveFfi::Ed25519);
        assert_eq!(key.depth(), 0);
    }

    #[test]
    fn from_raw_bytes_round_trips_through_export_raw() {
        let original = seed();
        let raw_bytes = original.export_raw();
        let restored = SeedFfi::from_raw_bytes(raw_bytes.clone()).unwrap();
        assert_eq!(restored.export_raw(), raw_bytes);
    }

    #[test]
    fn from_raw_bytes_produces_a_seed_deriving_the_same_master_key() {
        let original = seed();
        let restored = SeedFfi::from_raw_bytes(original.export_raw()).unwrap();
        assert_eq!(
            restored.master_key(CurveFfi::Secp256k1).public_key().raw_bytes(),
            original.master_key(CurveFfi::Secp256k1).public_key().raw_bytes()
        );
    }

    #[test]
    fn from_raw_bytes_rejects_the_wrong_byte_count() {
        assert!(matches!(
            SeedFfi::from_raw_bytes(vec![0u8; 63]),
            Err(WalletKitErrorFfi::InvalidSeed { .. })
        ));
    }
}
