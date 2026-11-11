//! SLIP-39 (Shamir's Secret Sharing for mnemonic codes): share decoding,
//! strict recovery of the encrypted master secret, and cancellable
//! passphrase decryption. Port of the reference implementation
//! (python-shamir-mnemonic). Only 20- and 33-word shares are supported.

mod gf256;

use std::collections::BTreeMap;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::OnceLock;

use hmac::{Hmac, Mac};
use sha2::Sha256;
use zeroize::{Zeroize, Zeroizing};

const RADIX_BITS: usize = 10;
const ID_EXP_LENGTH_WORDS: usize = 2;
const CHECKSUM_LENGTH_WORDS: usize = 3;
const METADATA_LENGTH_WORDS: usize = ID_EXP_LENGTH_WORDS + 2 + CHECKSUM_LENGTH_WORDS;
const DIGEST_LENGTH_BYTES: usize = 4;
const BASE_ITERATION_COUNT: u64 = 10_000;
const ROUND_COUNT: u8 = 4;
const SECRET_INDEX: u8 = 255;
const DIGEST_INDEX: u8 = 254;
const CANCEL_CHECK_INTERVAL: u64 = 10_000;

const SUPPORTED_WORD_COUNTS: [usize; 2] = [20, 33];

static WORDLIST: OnceLock<Vec<&'static str>> = OnceLock::new();

fn wordlist() -> &'static [&'static str] {
    WORDLIST.get_or_init(|| include_str!("wordlist.txt").lines().collect())
}

#[derive(Debug, Clone, PartialEq, Eq, thiserror::Error, uniffi::Error)]
pub enum Slip39ErrorFfi {
    #[error("unknown word: {word}")]
    UnknownWord { word: String },
    #[error("invalid checksum")]
    InvalidChecksum,
    #[error("unsupported share length: {count} words")]
    UnsupportedLength { count: u32 },
    #[error("invalid share: {reason}")]
    InvalidShare { reason: String },
    #[error("invalid set of shares: {reason}")]
    InvalidSet { reason: String },
    #[error("wrong number of shares: {reason}")]
    WrongShareCount { reason: String },
    #[error("invalid digest of the shared secret")]
    InvalidDigest,
    #[error("passphrase must use printable ASCII characters")]
    InvalidPassphrase,
    #[error("cancelled")]
    Cancelled,
}

/// Parsed metadata and value of one share.
#[derive(Debug, Clone, uniffi::Record)]
pub struct Slip39ShareFfi {
    pub identifier: u32,
    pub extendable: bool,
    pub iteration_exponent: u32,
    pub group_index: u32,
    pub group_threshold: u32,
    pub group_count: u32,
    pub member_index: u32,
    pub member_threshold: u32,
    pub word_count: u32,
    pub value: Vec<u8>,
}

struct Share {
    identifier: u32,
    extendable: bool,
    iteration_exponent: u32,
    group_index: u8,
    group_threshold: u8,
    group_count: u8,
    member_index: u8,
    member_threshold: u8,
    value: Vec<u8>,
}

fn word_index(word: &str) -> Option<u16> {
    wordlist().binary_search(&word).ok().map(|i| i as u16)
}

fn bits_to_bytes(n: usize) -> usize {
    (n + 7) / 8
}

fn customization_string(extendable: bool) -> &'static [u8] {
    if extendable {
        b"shamir_extendable"
    } else {
        b"shamir"
    }
}

fn rs1024_polymod(values: impl Iterator<Item = u32>) -> u32 {
    const GEN: [u32; 10] = [
        0xE0_E040, 0x1C1_C080, 0x383_8100, 0x707_0200, 0xE0E_0009, 0x1C0C_2412, 0x3808_6C24,
        0x3090_FC48, 0x21B1_F890, 0x3F3_F120,
    ];
    let mut chk: u32 = 1;
    for v in values {
        let b = chk >> 20;
        chk = ((chk & 0xF_FFFF) << 10) ^ v;
        for (i, g) in GEN.iter().enumerate() {
            if (b >> i) & 1 == 1 {
                chk ^= g;
            }
        }
    }
    chk
}

fn verify_checksum(data: &[u16], extendable: bool) -> bool {
    let values = customization_string(extendable)
        .iter()
        .map(|b| u32::from(*b))
        .chain(data.iter().map(|d| u32::from(*d)));
    rs1024_polymod(values) == 1
}

fn int_from_indices(indices: &[u16]) -> Vec<u8> {
    // Big-endian bytes of the base-1024 number, right-aligned.
    let mut bits = Vec::with_capacity(indices.len() * RADIX_BITS);
    for index in indices {
        for k in (0..RADIX_BITS).rev() {
            bits.push((index >> k) & 1 == 1);
        }
    }
    let mut bytes = vec![0u8; bits_to_bytes(bits.len())];
    let total = bits.len();
    for (i, bit) in bits.iter().enumerate() {
        if *bit {
            let from_end = total - 1 - i;
            let pos = bytes.len() - 1 - from_end / 8;
            bytes[pos] |= 1 << (from_end % 8);
        }
    }
    bytes
}

fn small_int(indices: &[u16]) -> u32 {
    indices.iter().fold(0u32, |acc, i| (acc << RADIX_BITS) + u32::from(*i))
}

fn decode_share(mnemonic: &str) -> Result<(Share, usize), Slip39ErrorFfi> {
    let mut data = Vec::new();
    for word in mnemonic.split_whitespace() {
        let lowered = word.to_lowercase();
        let index = word_index(&lowered).ok_or(Slip39ErrorFfi::UnknownWord { word: lowered })?;
        data.push(index);
    }

    if !SUPPORTED_WORD_COUNTS.contains(&data.len()) {
        return Err(Slip39ErrorFfi::UnsupportedLength {
            count: data.len() as u32,
        });
    }

    let padding_len = (RADIX_BITS * (data.len() - METADATA_LENGTH_WORDS)) % 16;
    if padding_len > 8 {
        return Err(Slip39ErrorFfi::InvalidShare {
            reason: "invalid length".to_string(),
        });
    }

    let id_exp = small_int(&data[..ID_EXP_LENGTH_WORDS]);
    let identifier = id_exp >> 5;
    let extendable = (id_exp >> 4) & 1 == 1;
    let iteration_exponent = id_exp & 0xF;

    if !verify_checksum(&data, extendable) {
        return Err(Slip39ErrorFfi::InvalidChecksum);
    }

    let tmp = small_int(&data[ID_EXP_LENGTH_WORDS..ID_EXP_LENGTH_WORDS + 2]);
    let field = |i: u32| ((tmp >> (i * 4)) & 0xF) as u8;
    let (group_index, group_threshold, group_count, member_index, member_threshold) =
        (field(4), field(3), field(2), field(1), field(0));

    let value_data = &data[ID_EXP_LENGTH_WORDS + 2..data.len() - CHECKSUM_LENGTH_WORDS];

    if group_count < group_threshold {
        return Err(Slip39ErrorFfi::InvalidShare {
            reason: "group threshold cannot be greater than group count".to_string(),
        });
    }

    if u32::from(value_data[0]) >= 1u32 << (RADIX_BITS - padding_len) {
        return Err(Slip39ErrorFfi::InvalidShare {
            reason: "invalid padding".to_string(),
        });
    }

    let value_byte_count = bits_to_bytes(RADIX_BITS * value_data.len() - padding_len);
    let full = int_from_indices(value_data);
    let value = full[full.len() - value_byte_count..].to_vec();

    Ok((
        Share {
            identifier,
            extendable,
            iteration_exponent,
            group_index,
            group_threshold: group_threshold + 1,
            group_count: group_count + 1,
            member_index,
            member_threshold: member_threshold + 1,
            value,
        },
        data.len(),
    ))
}

fn create_digest(random_data: &[u8], shared_secret: &[u8]) -> [u8; DIGEST_LENGTH_BYTES] {
    let mut mac = Hmac::<Sha256>::new_from_slice(random_data).expect("hmac accepts any key length");
    mac.update(shared_secret);
    let out = mac.finalize().into_bytes();
    let mut digest = [0u8; DIGEST_LENGTH_BYTES];
    digest.copy_from_slice(&out[..DIGEST_LENGTH_BYTES]);
    digest
}

fn recover_secret(threshold: u8, shares: &[(u8, Vec<u8>)]) -> Result<Vec<u8>, Slip39ErrorFfi> {
    if threshold == 1 {
        return Ok(shares[0].1.clone());
    }

    let shared_secret = gf256::interpolate(shares, SECRET_INDEX);
    let digest_share = gf256::interpolate(shares, DIGEST_INDEX);
    let (digest, random_part) = digest_share.split_at(DIGEST_LENGTH_BYTES);

    if digest != create_digest(random_part, &shared_secret) {
        return Err(Slip39ErrorFfi::InvalidDigest);
    }

    Ok(shared_secret)
}

fn passphrase_is_valid(passphrase: &str) -> bool {
    passphrase.bytes().all(|b| (32..=126).contains(&b))
}

fn salt(identifier: u32, extendable: bool) -> Vec<u8> {
    if extendable {
        return Vec::new();
    }
    let mut salt = b"shamir".to_vec();
    salt.extend_from_slice(&(identifier as u16).to_be_bytes());
    salt
}

/// PBKDF2-HMAC-SHA256 for a single output block (`len <= 32`), checking
/// `cancelled` periodically.
fn pbkdf2_block(
    password: &[u8],
    salt: &[u8],
    iterations: u64,
    len: usize,
    cancelled: &AtomicBool,
) -> Result<Zeroizing<Vec<u8>>, Slip39ErrorFfi> {
    if cancelled.load(Ordering::Relaxed) {
        return Err(Slip39ErrorFfi::Cancelled);
    }
    let base = Hmac::<Sha256>::new_from_slice(password).expect("hmac accepts any key length");
    let mut mac = base.clone();
    mac.update(salt);
    mac.update(&1u32.to_be_bytes());
    let mut u: [u8; 32] = mac.finalize().into_bytes().into();
    let mut t = u;

    for i in 1..iterations {
        if i % CANCEL_CHECK_INTERVAL == 0 && cancelled.load(Ordering::Relaxed) {
            u.zeroize();
            t.zeroize();
            return Err(Slip39ErrorFfi::Cancelled);
        }
        let mut mac = base.clone();
        mac.update(&u);
        u = mac.finalize().into_bytes().into();
        for (a, b) in t.iter_mut().zip(u.iter()) {
            *a ^= b;
        }
    }

    let out = Zeroizing::new(t[..len].to_vec());
    u.zeroize();
    t.zeroize();
    Ok(out)
}

fn decrypt_ems(
    ems: &[u8],
    passphrase: &[u8],
    iteration_exponent: u32,
    identifier: u32,
    extendable: bool,
    cancelled: &AtomicBool,
) -> Result<Vec<u8>, Slip39ErrorFfi> {
    let half = ems.len() / 2;
    let mut l = ems[..half].to_vec();
    let mut r = ems[half..].to_vec();
    let salt = salt(identifier, extendable);
    let iterations = (BASE_ITERATION_COUNT << iteration_exponent) / u64::from(ROUND_COUNT);

    for i in (0..ROUND_COUNT).rev() {
        let mut key = vec![i];
        key.extend_from_slice(passphrase);
        let mut salted = salt.clone();
        salted.extend_from_slice(&r);
        let f = pbkdf2_block(&key, &salted, iterations, r.len(), cancelled)?;
        key.zeroize();
        let new_r: Vec<u8> = l.iter().zip(f.iter()).map(|(a, b)| a ^ b).collect();
        l = std::mem::replace(&mut r, new_r);
    }

    if cancelled.load(Ordering::Relaxed) {
        return Err(Slip39ErrorFfi::Cancelled);
    }
    let mut out = r;
    out.extend_from_slice(&l);
    Ok(out)
}

fn encrypt_ems(
    master_secret: &[u8],
    passphrase: &[u8],
    iteration_exponent: u32,
    identifier: u32,
    extendable: bool,
    cancelled: &AtomicBool,
) -> Result<Vec<u8>, Slip39ErrorFfi> {
    let half = master_secret.len() / 2;
    let mut l = master_secret[..half].to_vec();
    let mut r = master_secret[half..].to_vec();
    let salt = salt(identifier, extendable);
    let iterations = (BASE_ITERATION_COUNT << iteration_exponent) / u64::from(ROUND_COUNT);

    for i in 0..ROUND_COUNT {
        let mut key = vec![i];
        key.extend_from_slice(passphrase);
        let mut salted = salt.clone();
        salted.extend_from_slice(&r);
        let f = pbkdf2_block(&key, &salted, iterations, r.len(), cancelled)?;
        key.zeroize();
        let new_r: Vec<u8> = l.iter().zip(f.iter()).map(|(a, b)| a ^ b).collect();
        l = std::mem::replace(&mut r, new_r);
    }

    let mut out = r;
    out.extend_from_slice(&l);
    Ok(out)
}

/// Encodes a share as words: metadata, value, RS1024 checksum.
fn encode_share(share: &Share) -> String {
    let words = wordlist();
    let mut indices: Vec<u16> = Vec::new();

    let id_exp = (share.identifier << 5) | (u32::from(share.extendable) << 4) | share.iteration_exponent;
    indices.push(((id_exp >> 10) & 0x3FF) as u16);
    indices.push((id_exp & 0x3FF) as u16);

    let nibbles = [
        share.group_index,
        share.group_threshold - 1,
        share.group_count - 1,
        share.member_index,
        share.member_threshold - 1,
    ];
    let packed = nibbles.iter().fold(0u32, |acc, n| (acc << 4) | u32::from(*n));
    indices.push(((packed >> 10) & 0x3FF) as u16);
    indices.push((packed & 0x3FF) as u16);

    // The value, left-padded with zero bits to a whole number of words.
    let value_words = (share.value.len() * 8 + RADIX_BITS - 1) / RADIX_BITS;
    let total_bits = value_words * RADIX_BITS;
    let pad = total_bits - share.value.len() * 8;
    let mut bits = vec![false; pad];
    for byte in &share.value {
        for k in (0..8).rev() {
            bits.push((byte >> k) & 1 == 1);
        }
    }
    for chunk in bits.chunks(RADIX_BITS) {
        indices.push(chunk.iter().fold(0u16, |acc, b| (acc << 1) | u16::from(*b)));
    }

    let values = customization_string(share.extendable)
        .iter()
        .map(|b| u32::from(*b))
        .chain(indices.iter().map(|i| u32::from(*i)))
        .chain([0u32; CHECKSUM_LENGTH_WORDS]);
    let polymod = rs1024_polymod(values) ^ 1;
    for i in (0..CHECKSUM_LENGTH_WORDS).rev() {
        indices.push(((polymod >> (10 * i)) & 0x3FF) as u16);
    }

    indices.iter().map(|i| words[usize::from(*i)]).collect::<Vec<_>>().join(" ")
}

/// A newly generated single-share backup.
#[derive(Debug, Clone, uniffi::Record)]
pub struct Slip39GeneratedFfi {
    /// The share's words (20 for 128-bit, 33 for 256-bit secrets).
    pub mnemonic: String,
    /// The master secret the share restores (with an empty passphrase).
    pub master_secret: Vec<u8>,
}

/// Generates a random master secret and its 1-of-1 share (empty
/// passphrase, extendable, iteration exponent 1 like Trezor's default).
/// `strength_bits` is 128 (20 words) or 256 (33 words).
#[uniffi::export]
pub fn slip39_generate_single_share(strength_bits: u32) -> Result<Slip39GeneratedFfi, Slip39ErrorFfi> {
    use rand::RngCore;

    if strength_bits != 128 && strength_bits != 256 {
        return Err(Slip39ErrorFfi::InvalidShare {
            reason: format!("unsupported strength: {strength_bits} bits"),
        });
    }

    let mut master_secret = Zeroizing::new(vec![0u8; (strength_bits / 8) as usize]);
    let mut rng = rand::rngs::OsRng;
    rng.fill_bytes(&mut master_secret);
    let identifier = rng.next_u32() & 0x7FFF;
    let iteration_exponent = 1;

    let ems = encrypt_ems(&master_secret, b"", iteration_exponent, identifier, true, &AtomicBool::new(false))?;

    let share = Share {
        identifier,
        extendable: true,
        iteration_exponent,
        group_index: 0,
        group_threshold: 1,
        group_count: 1,
        member_index: 0,
        member_threshold: 1,
        value: ems,
    };

    Ok(Slip39GeneratedFfi {
        mnemonic: encode_share(&share),
        master_secret: master_secret.to_vec(),
    })
}

/// The encrypted master secret recovered from a complete set of shares.
/// Decrypting it with a passphrase is slow (PBKDF2) and cancellable.
#[derive(uniffi::Object)]
pub struct Slip39EncryptedSecretFfi {
    ems: Zeroizing<Vec<u8>>,
    identifier: u32,
    extendable: bool,
    iteration_exponent: u32,
    cancelled: AtomicBool,
}

#[uniffi::export]
impl Slip39EncryptedSecretFfi {
    /// Applies `passphrase` (printable ASCII, used exactly as given) and
    /// returns the master secret. Throws `.cancelled` once `cancel()` was
    /// called (also before this call starts); use a fresh object to retry.
    pub fn decrypt(&self, passphrase: String) -> Result<Vec<u8>, Slip39ErrorFfi> {
        if !passphrase_is_valid(&passphrase) {
            return Err(Slip39ErrorFfi::InvalidPassphrase);
        }
        decrypt_ems(
            &self.ems,
            passphrase.as_bytes(),
            self.iteration_exponent,
            self.identifier,
            self.extendable,
            &self.cancelled,
        )
    }

    /// Asks a running `decrypt` to stop at its next check.
    pub fn cancel(&self) {
        self.cancelled.store(true, Ordering::Relaxed);
    }
}

/// The SLIP-39 wordlist (1024 words, alphabetical).
#[uniffi::export]
pub fn slip39_words() -> Vec<String> {
    wordlist().iter().map(|w| (*w).to_string()).collect()
}

/// Decodes one share mnemonic. Only 20- and 33-word shares are accepted.
#[uniffi::export]
pub fn slip39_decode_share(mnemonic: String) -> Result<Slip39ShareFfi, Slip39ErrorFfi> {
    let (share, word_count) = decode_share(&mnemonic)?;
    Ok(Slip39ShareFfi {
        identifier: share.identifier,
        extendable: share.extendable,
        iteration_exponent: share.iteration_exponent,
        group_index: u32::from(share.group_index),
        group_threshold: u32::from(share.group_threshold),
        group_count: u32::from(share.group_count),
        member_index: u32::from(share.member_index),
        member_threshold: u32::from(share.member_threshold),
        word_count: word_count as u32,
        value: share.value,
    })
}

/// Strictly combines exactly the required groups and members into the
/// encrypted master secret, checking the digest.
#[uniffi::export]
pub fn slip39_recover_encrypted_secret(
    mnemonics: Vec<String>,
) -> Result<std::sync::Arc<Slip39EncryptedSecretFfi>, Slip39ErrorFfi> {
    if mnemonics.is_empty() {
        return Err(Slip39ErrorFfi::WrongShareCount {
            reason: "no shares".to_string(),
        });
    }

    let mut first: Option<(u32, bool, u32, u8, u8, usize)> = None;
    let mut groups: BTreeMap<u8, (u8, Vec<(u8, Vec<u8>)>)> = BTreeMap::new();

    for mnemonic in &mnemonics {
        let (share, word_count) = decode_share(mnemonic)?;
        let meta = (
            share.identifier,
            share.extendable,
            share.iteration_exponent,
            share.group_threshold,
            share.group_count,
            word_count,
        );
        match first {
            None => first = Some(meta),
            Some(f) if f != meta => {
                return Err(Slip39ErrorFfi::InvalidSet {
                    reason: "shares belong to different backups or have different parameters"
                        .to_string(),
                })
            }
            _ => {}
        }
        let group = groups
            .entry(share.group_index)
            .or_insert((share.member_threshold, Vec::new()));
        if group.0 != share.member_threshold {
            return Err(Slip39ErrorFfi::InvalidSet {
                reason: "member threshold differs within a group".to_string(),
            });
        }
        if group.1.iter().any(|(i, _)| *i == share.member_index) {
            return Err(Slip39ErrorFfi::InvalidSet {
                reason: "member indices in a group must be unique".to_string(),
            });
        }
        group.1.push((share.member_index, share.value));
    }

    let (identifier, extendable, iteration_exponent, group_threshold, _, _) =
        first.expect("non-empty set");

    if groups.len() != usize::from(group_threshold) {
        return Err(Slip39ErrorFfi::WrongShareCount {
            reason: format!(
                "expected {group_threshold} groups, got {}",
                groups.len()
            ),
        });
    }

    let mut group_shares = Vec::new();
    for (group_index, (threshold, members)) in &groups {
        if members.len() != usize::from(*threshold) {
            return Err(Slip39ErrorFfi::WrongShareCount {
                reason: format!("expected {threshold} shares in a group, got {}", members.len()),
            });
        }
        group_shares.push((*group_index, recover_secret(*threshold, members)?));
    }

    let ems = recover_secret(group_threshold, &group_shares)?;

    Ok(std::sync::Arc::new(Slip39EncryptedSecretFfi {
        ems: Zeroizing::new(ems),
        identifier,
        extendable,
        iteration_exponent,
        cancelled: AtomicBool::new(false),
    }))
}

#[cfg(test)]
mod tests {
    use super::*;

    struct Vectors {
        passphrase: String,
        vectors: Vec<Vector>,
    }

    struct Vector {
        mnemonics: Vec<String>,
        master_secret: String,
    }

    fn vectors() -> Vectors {
        let json: serde_json::Value =
            serde_json::from_str(include_str!("../../../../../../TestVectors/slip39.json")).unwrap();
        Vectors {
            passphrase: json["passphrase"].as_str().unwrap().to_string(),
            vectors: json["vectors"]
                .as_array()
                .unwrap()
                .iter()
                .map(|v| Vector {
                    mnemonics: v["mnemonics"]
                        .as_array()
                        .unwrap()
                        .iter()
                        .map(|m| m.as_str().unwrap().to_string())
                        .collect(),
                    master_secret: v["masterSecret"].as_str().unwrap().to_string(),
                })
                .collect(),
        }
    }

    #[test]
    fn wordlist_has_1024_sorted_words() {
        let words = wordlist();
        assert_eq!(words.len(), 1024);
        assert!(words.windows(2).all(|w| w[0] < w[1]));
    }

    #[test]
    fn official_vectors() {
        let v = vectors();
        for (n, vector) in v.vectors.iter().enumerate() {
            let result = slip39_recover_encrypted_secret(vector.mnemonics.clone())
                .and_then(|ems| ems.decrypt(v.passphrase.clone()));
            if vector.master_secret.is_empty() {
                assert!(result.is_err(), "vector {n} should be invalid");
            } else {
                assert_eq!(
                    hex::encode(result.unwrap_or_else(|e| panic!("vector {n}: {e}"))),
                    vector.master_secret,
                    "vector {n}"
                );
            }
        }
    }

    #[test]
    fn encoding_reproduces_official_share_mnemonics() {
        let v = vectors();
        for vector in v.vectors.iter().filter(|v| !v.master_secret.is_empty()) {
            for mnemonic in &vector.mnemonics {
                let (share, _) = decode_share(mnemonic).unwrap();
                assert_eq!(&encode_share(&share), mnemonic);
            }
        }
    }

    #[test]
    fn generated_single_shares_restore_their_master_secret() {
        for (bits, words) in [(128u32, 20usize), (256, 33)] {
            let generated = slip39_generate_single_share(bits).unwrap();
            assert_eq!(generated.mnemonic.split(' ').count(), words);

            let share = slip39_decode_share(generated.mnemonic.clone()).unwrap();
            assert_eq!((share.group_threshold, share.member_threshold), (1, 1));

            let restored = slip39_recover_encrypted_secret(vec![generated.mnemonic])
                .unwrap()
                .decrypt(String::new())
                .unwrap();
            assert_eq!(restored, generated.master_secret);
        }
        assert!(slip39_generate_single_share(192).is_err());
    }

    #[test]
    fn rejects_non_ascii_passphrase() {
        let v = vectors();
        let ems = slip39_recover_encrypted_secret(v.vectors[0].mnemonics.clone()).unwrap();
        assert_eq!(ems.decrypt("pässword".to_string()), Err(Slip39ErrorFfi::InvalidPassphrase));
    }

    #[test]
    fn cancel_stops_decryption() {
        let v = vectors();
        let ems = slip39_recover_encrypted_secret(v.vectors[0].mnemonics.clone()).unwrap();
        // Exponent is small in the vectors, so cancel from the start via the
        // internal helper with a pre-set flag.
        let flag = AtomicBool::new(true);
        let r = pbkdf2_block(b"p", b"s", 100_000, 16, &flag);
        assert_eq!(r.err(), Some(Slip39ErrorFfi::Cancelled));
        let _ = ems;
    }

    #[test]
    fn pre_cancelled_decryption_never_returns_a_secret() {
        let generated = slip39_generate_single_share(128).unwrap();
        let ems = slip39_recover_encrypted_secret(vec![generated.mnemonic]).unwrap();
        ems.cancel();
        assert_eq!(ems.decrypt(String::new()), Err(Slip39ErrorFfi::Cancelled));
    }

    #[test]
    fn mixed_length_shares_are_rejected_in_both_orders() {
        let v = vectors();
        let vector = v
            .vectors
            .iter()
            .find(|v| !v.master_secret.is_empty() && v.mnemonics.len() >= 2 && v.mnemonics[0].split(' ').count() == 20)
            .expect("multi-share 20-word vector");
        let (mut share, _) = decode_share(&vector.mnemonics[0]).unwrap();
        share.value.extend_from_slice(&[0u8; 16]);
        let longer = encode_share(&share);
        assert_eq!(longer.split(' ').count(), 33);

        let mut first = vector.mnemonics.clone();
        first[0] = longer.clone();
        let mut last = vector.mnemonics.clone();
        last.rotate_left(1);
        *last.last_mut().unwrap() = longer;

        for set in [first, last] {
            assert!(matches!(
                slip39_recover_encrypted_secret(set),
                Err(Slip39ErrorFfi::InvalidSet { .. })
            ));
        }
    }
}
