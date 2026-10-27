//! CIP-8 message signing (CIP-30 `signData`).
//!
//! The COSE structures are hand-encoded: they are tiny and fixed, and software
//! and hardware signers must produce byte-identical output, so both go
//! through `assemble`. CIP-30 signs the supplied payload un-hashed.

use cardano_serialization_lib::{Bip32PrivateKey, PublicKey};

use crate::blockchain_clients::cardano::{signing_failed, CardanoSigningPathFfi};
use crate::errors::WalletKitErrorFfi;

const ALG_EDDSA: i64 = -8;
const CARDANO_COIN_TYPE: u32 = 1815;
const CIP1852_PURPOSE: u32 = 1852;
const CRV_ED25519: u64 = 6;
const HARDENED: u32 = 0x8000_0000;
const KTY_OKP: u64 = 1;
const MAX_ROLE: u32 = 2;

#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct CardanoCip8Ffi {
    /// `COSE_Key`, CBOR.
    pub key: Vec<u8>,
    /// `COSE_Sign1`, CBOR.
    pub signature: Vec<u8>,
}

fn head(major: u8, value: u64, out: &mut Vec<u8>) {
    let major = major << 5;
    match value {
        0..=23 => out.push(major | value as u8),
        24..=0xFF => out.extend([major | 24, value as u8]),
        0x100..=0xFFFF => {
            out.push(major | 25);
            out.extend((value as u16).to_be_bytes());
        }
        0x1_0000..=0xFFFF_FFFF => {
            out.push(major | 26);
            out.extend((value as u32).to_be_bytes());
        }
        _ => {
            out.push(major | 27);
            out.extend(value.to_be_bytes());
        }
    }
}

fn int(value: i64, out: &mut Vec<u8>) {
    if value >= 0 {
        head(0, value as u64, out);
    } else {
        head(1, (-1 - value) as u64, out);
    }
}

fn bytes(value: &[u8], out: &mut Vec<u8>) {
    head(2, value.len() as u64, out);
    out.extend(value);
}

fn text(value: &str, out: &mut Vec<u8>) {
    head(3, value.len() as u64, out);
    out.extend(value.as_bytes());
}

/// `{1: -8, "address": address}`
fn protected_header(address: &[u8]) -> Vec<u8> {
    let mut out = vec![];
    head(5, 2, &mut out);
    int(1, &mut out);
    int(ALG_EDDSA, &mut out);
    text("address", &mut out);
    bytes(address, &mut out);
    out
}

/// `["Signature1", protected, h'', payload]`
pub(crate) fn signature_structure(address: &[u8], payload: &[u8]) -> Vec<u8> {
    let mut out = vec![];
    head(4, 4, &mut out);
    text("Signature1", &mut out);
    bytes(&protected_header(address), &mut out);
    bytes(&[], &mut out);
    bytes(payload, &mut out);
    out
}

/// Builds `COSE_Sign1` and `COSE_Key` from a signature produced elsewhere
/// (software key or Trezor) over `signature_structure(address, payload)`.
#[uniffi::export]
pub fn cardano_cip8_assemble(
    signature: Vec<u8>,
    public_key: Vec<u8>,
    address: Vec<u8>,
    payload: Vec<u8>,
) -> Result<CardanoCip8Ffi, WalletKitErrorFfi> {
    if signature.len() != 64 {
        return Err(signing_failed("Cardano CIP-8 signature must be 64 bytes"));
    }
    if public_key.len() != 32 {
        return Err(signing_failed("Cardano CIP-8 public key must be 32 bytes"));
    }

    let mut sign1 = vec![];
    head(4, 4, &mut sign1);
    bytes(&protected_header(&address), &mut sign1);
    // Unprotected: {"hashed": false, "version": 1}
    head(5, 2, &mut sign1);
    text("hashed", &mut sign1);
    sign1.push(0xF4);
    text("version", &mut sign1);
    int(1, &mut sign1);
    bytes(&payload, &mut sign1);
    bytes(&signature, &mut sign1);

    // {1: 1, 3: -8, -1: 6, -2: public_key}
    let mut key = vec![];
    head(5, 4, &mut key);
    int(1, &mut key);
    head(0, KTY_OKP, &mut key);
    int(3, &mut key);
    int(ALG_EDDSA, &mut key);
    int(-1, &mut key);
    head(0, CRV_ED25519, &mut key);
    int(-2, &mut key);
    bytes(&public_key, &mut key);

    Ok(CardanoCip8Ffi { key, signature: sign1 })
}

/// Signs `payload` un-hashed with the account key at `signing_path`.
/// `address` (raw bytes) goes in the protected header; the caller has already
/// checked that `signing_path` is the key behind it.
#[uniffi::export]
pub fn cardano_cip8_sign_data(
    entropy: Vec<u8>,
    account_index: u32,
    signing_path: CardanoSigningPathFfi,
    address: Vec<u8>,
    payload: Vec<u8>,
) -> Result<CardanoCip8Ffi, WalletKitErrorFfi> {
    if entropy.is_empty() {
        return Err(WalletKitErrorFfi::InvalidEntropy);
    }
    if signing_path.role > MAX_ROLE {
        return Err(signing_failed("Cardano signing path has an unsupported role"));
    }

    let key = Bip32PrivateKey::from_bip39_entropy(&entropy, &[])
        .derive(CIP1852_PURPOSE | HARDENED)
        .derive(CARDANO_COIN_TYPE | HARDENED)
        .derive(account_index | HARDENED)
        .derive(signing_path.role)
        .derive(signing_path.index)
        .to_raw_key();
    let signature = key.sign(&signature_structure(&address, &payload));
    let public_key: PublicKey = key.to_public();

    cardano_cip8_assemble(signature.to_bytes(), public_key.as_bytes(), address, payload)
}

#[cfg(test)]
pub(super) fn structure_for_tests(address: &[u8], payload: &[u8]) -> Vec<u8> {
    signature_structure(address, payload)
}
