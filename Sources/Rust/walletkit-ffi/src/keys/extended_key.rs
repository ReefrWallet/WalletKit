//! `ExtendedKeyFfi`: a node in an HD key tree, covering BIP32 (secp256k1) and
//! SLIP-0010 (ed25519) derivation. See
//! `Walletkit/Docs/Design Specification/Keys/ExtendedKeyFfi.swift`.

use hmac::{Hmac, Mac};
use ripemd::Ripemd160;
use sha2::{Digest, Sha256, Sha512};
use std::sync::Arc;
use zeroize::Zeroizing;

use crate::common::{CurveFfi, DerivationPath, DerivationScheme};
use crate::errors::WalletKitErrorFfi;
use crate::keys::private_key::PrivateKeyFfi;
use crate::keys::public_key::PublicKeyFfi;

type HmacSha512 = Hmac<Sha512>;

const XPRV_VERSION: [u8; 4] = [0x04, 0x88, 0xAD, 0xE4];
const XPUB_VERSION: [u8; 4] = [0x04, 0x88, 0xB2, 0x1E];
const HARDENED_OFFSET: u32 = 0x8000_0000;
/// Marker byte distinguishing a raw (unprefixed) ed25519 public key from a
/// secp256k1 compressed public key (which always starts with 0x02/0x03) in
/// the shared 33-byte key field. Not a standard, since SLIP-0010 doesn't
/// define an extended-public-key serialization of its own.
const ED25519_PUBLIC_KEY_MARKER: u8 = 0x01;

#[derive(Clone, uniffi::Object)]
pub struct ExtendedKeyFfi {
    curve: CurveFfi,
    depth: u8,
    child_index: u32,
    is_hardened: bool,
    parent_fingerprint: [u8; 4],
    chain_code: [u8; 32],
    private_key: Option<Zeroizing<[u8; 32]>>,
    public_key_bytes: Vec<u8>,
}

impl std::fmt::Debug for ExtendedKeyFfi {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("ExtendedKeyFfi")
            .field("curve", &self.curve)
            .field("depth", &self.depth)
            .field("can_derive_private", &self.can_derive_private())
            .finish_non_exhaustive()
    }
}

impl ExtendedKeyFfi {
    /// Derives the master key for `curve` from a BIP39 seed via HMAC-SHA512
    /// with the scheme's standard key ("Bitcoin seed" / "ed25519 seed").
    pub(crate) fn master(curve: CurveFfi, seed: &[u8]) -> ExtendedKeyFfi {
        let hmac_key: &[u8] = match curve {
            CurveFfi::Secp256k1 => b"Bitcoin seed",
            CurveFfi::Ed25519 => b"ed25519 seed",
        };
        let (private_key, chain_code) = hmac_sha512_split(hmac_key, seed);
        Self::from_private_key(curve, 0, 0, false, [0; 4], chain_code, private_key)
    }

    fn from_private_key(
        curve: CurveFfi,
        depth: u8,
        child_index: u32,
        is_hardened: bool,
        parent_fingerprint: [u8; 4],
        chain_code: [u8; 32],
        private_key: [u8; 32],
    ) -> ExtendedKeyFfi {
        ExtendedKeyFfi {
            curve,
            depth,
            child_index,
            is_hardened,
            parent_fingerprint,
            chain_code,
            public_key_bytes: public_key_bytes_for(curve, &private_key),
            private_key: Some(Zeroizing::new(private_key)),
        }
    }

    /// Owned, non-FFI variant of `derive_child` used internally for
    /// chaining a full `DerivationPath`.
    fn derive_child_owned(&self, index: u32, hardened: bool) -> Result<ExtendedKeyFfi, WalletKitErrorFfi> {
        if index >= HARDENED_OFFSET {
            return Err(WalletKitErrorFfi::InvalidDerivationPath {
                path: format!("child index {index} is out of range"),
            });
        }
        match self.curve {
            CurveFfi::Secp256k1 => self.derive_child_secp256k1(index, hardened),
            CurveFfi::Ed25519 => self.derive_child_ed25519(index, hardened),
        }
    }

    fn derive_child_secp256k1(&self, index: u32, hardened: bool) -> Result<ExtendedKeyFfi, WalletKitErrorFfi> {
        let child_number = if hardened { index | HARDENED_OFFSET } else { index };
        let mut data = Vec::with_capacity(37);
        if hardened {
            let private_key = self.private_key.as_ref().ok_or(WalletKitErrorFfi::KeyNotFound)?;
            data.push(0);
            data.extend_from_slice(private_key.as_slice());
        } else {
            data.extend_from_slice(&self.public_key_bytes);
        }
        data.extend_from_slice(&child_number.to_be_bytes());

        let (tweak_bytes, chain_code) = hmac_sha512_split(&self.chain_code, &data);
        let secp = secp256k1::Secp256k1::new();
        let tweak = secp256k1::Scalar::from_be_bytes(tweak_bytes)
            .map_err(|_| WalletKitErrorFfi::InternalError { message: "invalid BIP32 tweak".to_string() })?;

        if let Some(parent_private) = &self.private_key {
            let parent_bytes: [u8; 32] = parent_private.as_slice().try_into().unwrap();
            let secret = secp256k1::SecretKey::from_byte_array(parent_bytes)
                .map_err(|err| WalletKitErrorFfi::InternalError { message: err.to_string() })?;
            let child_secret = secret
                .add_tweak(&tweak)
                .map_err(|err| WalletKitErrorFfi::InternalError { message: err.to_string() })?;
            Ok(ExtendedKeyFfi::from_private_key(
                CurveFfi::Secp256k1,
                self.depth + 1,
                index,
                hardened,
                self.fingerprint(),
                chain_code,
                child_secret.secret_bytes(),
            ))
        } else {
            let parent_public = secp256k1::PublicKey::from_slice(&self.public_key_bytes)
                .map_err(|err| WalletKitErrorFfi::InternalError { message: err.to_string() })?;
            let child_public = parent_public
                .add_exp_tweak(&secp, &tweak)
                .map_err(|err| WalletKitErrorFfi::InternalError { message: err.to_string() })?;
            Ok(ExtendedKeyFfi {
                curve: CurveFfi::Secp256k1,
                depth: self.depth + 1,
                child_index: index,
                is_hardened: hardened,
                parent_fingerprint: self.fingerprint(),
                chain_code,
                private_key: None,
                public_key_bytes: child_public.serialize().to_vec(),
            })
        }
    }

    fn derive_child_ed25519(&self, index: u32, hardened: bool) -> Result<ExtendedKeyFfi, WalletKitErrorFfi> {
        if !hardened {
            return Err(WalletKitErrorFfi::InvalidDerivationPath {
                path: "ed25519 (SLIP-0010) only supports hardened derivation".to_string(),
            });
        }
        let private_key = self.private_key.as_ref().ok_or(WalletKitErrorFfi::KeyNotFound)?;
        let child_number = index | HARDENED_OFFSET;

        let mut data = Vec::with_capacity(37);
        data.push(0);
        data.extend_from_slice(private_key.as_slice());
        data.extend_from_slice(&child_number.to_be_bytes());

        let (child_private_key, chain_code) = hmac_sha512_split(&self.chain_code, &data);
        Ok(ExtendedKeyFfi::from_private_key(
            CurveFfi::Ed25519,
            self.depth + 1,
            index,
            true,
            self.fingerprint(),
            chain_code,
            child_private_key,
        ))
    }

    fn fingerprint(&self) -> [u8; 4] {
        let sha256 = Sha256::digest(&self.public_key_bytes);
        let ripemd = Ripemd160::digest(sha256);
        [ripemd[0], ripemd[1], ripemd[2], ripemd[3]]
    }

    fn serialize(&self, private: bool) -> String {
        let mut buf = Vec::with_capacity(78);
        buf.extend_from_slice(if private { &XPRV_VERSION } else { &XPUB_VERSION });
        buf.push(self.depth);
        buf.extend_from_slice(&self.parent_fingerprint);
        let child_number = if self.is_hardened { self.child_index | HARDENED_OFFSET } else { self.child_index };
        buf.extend_from_slice(&child_number.to_be_bytes());
        buf.extend_from_slice(&self.chain_code);
        if private {
            buf.push(0);
            buf.extend_from_slice(self.private_key.as_ref().expect("checked by caller").as_slice());
        } else {
            match self.curve {
                CurveFfi::Secp256k1 => buf.extend_from_slice(&self.public_key_bytes),
                CurveFfi::Ed25519 => {
                    buf.push(ED25519_PUBLIC_KEY_MARKER);
                    buf.extend_from_slice(&self.public_key_bytes);
                }
            }
        }
        bs58::encode(buf).with_check().into_string()
    }

    fn from_serialized_owned(string: &str, curve: CurveFfi) -> Result<ExtendedKeyFfi, WalletKitErrorFfi> {
        let invalid = || WalletKitErrorFfi::InvalidDerivationPath { path: string.to_string() };

        let data = bs58::decode(string)
            .with_check(None)
            .into_vec()
            .map_err(|_| invalid())?;
        if data.len() != 78 {
            return Err(invalid());
        }

        let version: [u8; 4] = data[0..4].try_into().unwrap();
        let is_private = if version == XPRV_VERSION {
            true
        } else if version == XPUB_VERSION {
            false
        } else {
            return Err(invalid());
        };

        let depth = data[4];
        let parent_fingerprint: [u8; 4] = data[5..9].try_into().unwrap();
        let child_number = u32::from_be_bytes(data[9..13].try_into().unwrap());
        let is_hardened = child_number & HARDENED_OFFSET != 0;
        let child_index = child_number & !HARDENED_OFFSET;
        let chain_code: [u8; 32] = data[13..45].try_into().unwrap();
        let key_field = &data[45..78];

        if is_private {
            if key_field[0] != 0 {
                return Err(invalid());
            }
            let private_key: [u8; 32] = key_field[1..33].try_into().unwrap();
            Ok(ExtendedKeyFfi::from_private_key(
                curve,
                depth,
                child_index,
                is_hardened,
                parent_fingerprint,
                chain_code,
                private_key,
            ))
        } else {
            let public_key_bytes = match curve {
                CurveFfi::Secp256k1 => {
                    secp256k1::PublicKey::from_slice(key_field).map_err(|_| invalid())?;
                    key_field.to_vec()
                }
                CurveFfi::Ed25519 => {
                    if key_field[0] != ED25519_PUBLIC_KEY_MARKER {
                        return Err(invalid());
                    }
                    key_field[1..33].to_vec()
                }
            };
            Ok(ExtendedKeyFfi {
                curve,
                depth,
                child_index,
                is_hardened,
                parent_fingerprint,
                chain_code,
                private_key: None,
                public_key_bytes,
            })
        }
    }
}

#[uniffi::export]
impl ExtendedKeyFfi {
    /// Imports a serialized extended key string. `curve` disambiguates
    /// formats that don't self-describe their curve.
    #[uniffi::constructor]
    pub fn from_serialized(string: String, curve: CurveFfi) -> Result<Self, WalletKitErrorFfi> {
        Self::from_serialized_owned(&string, curve)
    }

    pub fn curve(&self) -> CurveFfi {
        self.curve
    }

    pub fn scheme(&self) -> DerivationScheme {
        DerivationScheme::for_curve(self.curve)
    }

    pub fn depth(&self) -> u8 {
        self.depth
    }

    pub fn child_index(&self) -> u32 {
        self.child_index
    }

    pub fn is_hardened(&self) -> bool {
        self.is_hardened
    }

    pub fn can_derive_private(&self) -> bool {
        self.private_key.is_some()
    }

    pub fn public_key(&self) -> Arc<PublicKeyFfi> {
        Arc::new(PublicKeyFfi::new(self.curve, self.public_key_bytes.clone()))
    }

    pub fn private_key(&self) -> Result<Arc<PrivateKeyFfi>, WalletKitErrorFfi> {
        let bytes: [u8; 32] = self
            .private_key
            .as_ref()
            .ok_or(WalletKitErrorFfi::KeyNotFound)?
            .as_slice()
            .try_into()
            .expect("private key is always 32 bytes");
        Ok(Arc::new(PrivateKeyFfi::new(self.curve, bytes)))
    }

    pub fn derive(&self, path: DerivationPath) -> Result<Arc<ExtendedKeyFfi>, WalletKitErrorFfi> {
        let mut current = self.clone();
        for segment in &path.segments {
            current = current.derive_child_owned(segment.index, segment.hardened)?;
        }
        Ok(Arc::new(current))
    }

    pub fn derive_child(&self, index: u32, hardened: bool) -> Result<Arc<ExtendedKeyFfi>, WalletKitErrorFfi> {
        self.derive_child_owned(index, hardened).map(Arc::new)
    }

    pub fn serialized_public(&self) -> String {
        self.serialize(false)
    }

    pub fn serialized_private(&self) -> Result<String, WalletKitErrorFfi> {
        if self.private_key.is_none() {
            return Err(WalletKitErrorFfi::KeyNotFound);
        }
        Ok(self.serialize(true))
    }
}

fn hmac_sha512_split(key: &[u8], data: &[u8]) -> ([u8; 32], [u8; 32]) {
    let mut mac = <HmacSha512 as Mac>::new_from_slice(key).expect("HMAC accepts any key length");
    Mac::update(&mut mac, data);
    let result = mac.finalize().into_bytes();
    let mut left = [0u8; 32];
    let mut right = [0u8; 32];
    left.copy_from_slice(&result[..32]);
    right.copy_from_slice(&result[32..]);
    (left, right)
}

fn public_key_bytes_for(curve: CurveFfi, private_key: &[u8; 32]) -> Vec<u8> {
    match curve {
        CurveFfi::Secp256k1 => {
            let secp = secp256k1::Secp256k1::signing_only();
            let secret = secp256k1::SecretKey::from_byte_array(*private_key)
                .expect("BIP32 derivation always produces a valid secp256k1 scalar");
            secp256k1::PublicKey::from_secret_key(&secp, &secret).serialize().to_vec()
        }
        CurveFfi::Ed25519 => {
            let signing_key = ed25519_dalek::SigningKey::from_bytes(private_key);
            signing_key.verifying_key().to_bytes().to_vec()
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::common::{MnemonicWordCount, Wordlist};
    use crate::keys::MnemonicFfi;

    fn master(curve: CurveFfi) -> Arc<ExtendedKeyFfi> {
        MnemonicFfi::generate(MnemonicWordCount::Words24, Wordlist::English)
            .to_seed("".to_string())
            .master_key(curve)
    }

    #[test]
    fn derive_walks_the_full_requested_path() {
        let master = master(CurveFfi::Secp256k1);
        let path = DerivationPath::parse("m/44'/60'/0'/0/0").unwrap();
        let derived = master.derive(path.clone()).unwrap();
        assert_eq!(derived.depth() as usize, path.segments.len());
    }

    #[test]
    fn derive_child_increments_depth_by_one() {
        let master = master(CurveFfi::Secp256k1);
        let child = master.derive_child(0, true).unwrap();
        assert_eq!(child.depth(), master.depth() + 1);
        assert!(child.is_hardened());
    }

    #[test]
    fn public_only_key_cannot_produce_a_private_key() {
        let master = master(CurveFfi::Secp256k1);
        let watch_only = ExtendedKeyFfi::from_serialized(master.serialized_public(), CurveFfi::Secp256k1).unwrap();
        assert!(!watch_only.can_derive_private());
        assert!(matches!(watch_only.private_key(), Err(WalletKitErrorFfi::KeyNotFound)));
    }

    #[test]
    fn serialized_private_round_trips_to_the_same_public_key() {
        let master = master(CurveFfi::Secp256k1);
        let restored =
            ExtendedKeyFfi::from_serialized(master.serialized_private().unwrap(), CurveFfi::Secp256k1).unwrap();
        assert_eq!(restored.serialized_public(), master.serialized_public());
    }

    #[test]
    fn invalid_serialized_string_throws() {
        let err = ExtendedKeyFfi::from_serialized("not-a-valid-xprv".to_string(), CurveFfi::Secp256k1).unwrap_err();
        assert!(matches!(err, WalletKitErrorFfi::InvalidDerivationPath { .. }));
    }
}
