//! `MnemonicFfi`: a BIP39 mnemonic. Holds the recovery phrase in
//! Rust-managed, zeroized memory; the phrase is only copied across the
//! FFI boundary when `phrase()` is read explicitly.

use std::sync::Arc;

use bip39::{Language, Mnemonic as Bip39Mnemonic};

use crate::common::{MnemonicWordCount, Wordlist};
use crate::errors::WalletKitErrorFfi;
use crate::keys::SeedFfi;

fn language(wordlist: Wordlist) -> Language {
    match wordlist {
        Wordlist::English => Language::English,
        Wordlist::ChineseSimplified => Language::SimplifiedChinese,
        Wordlist::ChineseTraditional => Language::TraditionalChinese,
        Wordlist::Czech => Language::Czech,
        Wordlist::French => Language::French,
        Wordlist::Italian => Language::Italian,
        Wordlist::Japanese => Language::Japanese,
        Wordlist::Korean => Language::Korean,
        Wordlist::Portuguese => Language::Portuguese,
        Wordlist::Spanish => Language::Spanish,
    }
}

#[derive(uniffi::Object)]
pub struct MnemonicFfi {
    inner: Bip39Mnemonic,
    word_count: MnemonicWordCount,
    wordlist: Wordlist,
}

impl std::fmt::Debug for MnemonicFfi {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("MnemonicFfi").finish_non_exhaustive()
    }
}

#[uniffi::export]
impl MnemonicFfi {
    /// Generates a new mnemonic with freshly-generated entropy.
    #[uniffi::constructor]
    pub fn generate(word_count: MnemonicWordCount, wordlist: Wordlist) -> MnemonicFfi {
        let inner = Bip39Mnemonic::generate_in(language(wordlist), word_count as usize)
            .expect("MnemonicWordCount is always a valid BIP39 word count");
        MnemonicFfi {
            inner,
            word_count,
            wordlist,
        }
    }

    /// Validates the BIP39 checksum; fails with `InvalidMnemonic` otherwise.
    #[uniffi::constructor]
    pub fn from_phrase(phrase: String, wordlist: Wordlist) -> Result<MnemonicFfi, WalletKitErrorFfi> {
        let inner = Bip39Mnemonic::parse_in_normalized(language(wordlist), &phrase)
            .map_err(|err| WalletKitErrorFfi::InvalidMnemonic {
                reason: err.to_string(),
            })?;
        let word_count = MnemonicWordCount::from_word_count(inner.word_count())
            .expect("BIP39 mnemonics always have a supported word count");
        Ok(MnemonicFfi {
            inner,
            word_count,
            wordlist,
        })
    }

    /// Reconstructs a mnemonic from its original BIP-39 entropy.
    #[uniffi::constructor]
    pub fn from_entropy(entropy: Vec<u8>, wordlist: Wordlist) -> Result<MnemonicFfi, WalletKitErrorFfi> {
        let inner = Bip39Mnemonic::from_entropy_in(language(wordlist), &entropy)
            .map_err(|_| WalletKitErrorFfi::InvalidEntropy)?;
        let word_count = MnemonicWordCount::from_word_count(inner.word_count())
            .expect("BIP39 mnemonics always have a supported word count");
        Ok(MnemonicFfi {
            inner,
            word_count,
            wordlist,
        })
    }

    pub fn phrase(&self) -> String {
        self.inner.to_string()
    }

    pub fn word_count(&self) -> MnemonicWordCount {
        self.word_count
    }

    pub fn wordlist(&self) -> Wordlist {
        self.wordlist
    }

    /// The original BIP-39 entropy. Cardano's Icarus key hierarchy needs
    /// this value rather than the derived 64-byte BIP-39 seed.
    pub fn entropy(&self) -> Vec<u8> {
        self.inner.to_entropy()
    }

    /// Derives the 64-byte BIP39 seed from this mnemonic + optional
    /// passphrase (the "25th word").
    pub fn to_seed(&self, passphrase: String) -> Arc<SeedFfi> {
        Arc::new(SeedFfi::new(self.inner.to_seed(passphrase)))
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::test_vectors::english_vectors;

    #[test]
    fn from_phrase_matches_official_bip39_vectors() {
        for (entropy_hex, phrase, seed_hex, master_xprv) in english_vectors() {
            let mnemonic = MnemonicFfi::from_phrase(phrase.clone(), Wordlist::English)
                .unwrap_or_else(|err| panic!("failed to parse vector {entropy_hex}: {err}"));

            assert_eq!(mnemonic.phrase(), phrase, "entropy {entropy_hex}");
            assert_eq!(mnemonic.wordlist(), Wordlist::English, "entropy {entropy_hex}");
            let seed = mnemonic.to_seed("TREZOR".to_string());
            assert_eq!(hex::encode(seed.export_raw()), seed_hex, "entropy {entropy_hex}");
            let master = seed.master_key(crate::common::CurveFfi::Secp256k1);
            assert_eq!(master.serialized_private().unwrap(), master_xprv, "entropy {entropy_hex}");
        }
    }

    #[test]
    fn from_entropy_recreates_the_same_seed() {
        let (entropy_hex, phrase, seed_hex, _) = english_vectors().into_iter().next().unwrap();
        let entropy = hex::decode(entropy_hex).unwrap();
        let mnemonic = MnemonicFfi::from_entropy(entropy, Wordlist::English).unwrap();

        assert_eq!(mnemonic.phrase(), phrase);
        assert_eq!(hex::encode(mnemonic.to_seed("TREZOR".to_string()).export_raw()), seed_hex);
    }

    #[test]
    fn generate_produces_a_valid_checksum_for_every_word_count() {
        for word_count in [
            MnemonicWordCount::Words12,
            MnemonicWordCount::Words15,
            MnemonicWordCount::Words18,
            MnemonicWordCount::Words21,
            MnemonicWordCount::Words24,
        ] {
            let mnemonic = MnemonicFfi::generate(word_count, Wordlist::English);
            assert_eq!(mnemonic.word_count(), word_count);
            assert_eq!(
                mnemonic.phrase().split(' ').count(),
                word_count as usize
            );
            // Must round-trip through from_phrase (validates the checksum).
            MnemonicFfi::from_phrase(mnemonic.phrase(), Wordlist::English).unwrap();
        }
    }

    #[test]
    fn from_phrase_rejects_an_invalid_phrase() {
        let err = MnemonicFfi::from_phrase("definitely not a bip39 phrase".to_string(), Wordlist::English)
            .unwrap_err();
        assert!(matches!(err, WalletKitErrorFfi::InvalidMnemonic { .. }));
    }

    #[test]
    fn from_phrase_matches_official_bip39_vectors_for_every_supported_wordlist() {
        let wordlists = [
            ("chinese_simplified", Wordlist::ChineseSimplified),
            ("chinese_traditional", Wordlist::ChineseTraditional),
            ("czech", Wordlist::Czech),
            ("french", Wordlist::French),
            ("italian", Wordlist::Italian),
            ("japanese", Wordlist::Japanese),
            ("korean", Wordlist::Korean),
            ("portuguese", Wordlist::Portuguese),
            ("spanish", Wordlist::Spanish),
        ];
        for (language_key, wordlist) in wordlists {
            for (entropy_hex, phrase, seed_hex, _master_xprv) in crate::test_vectors::vectors_for(language_key) {
                let mnemonic = MnemonicFfi::from_phrase(phrase.clone(), wordlist).unwrap_or_else(|err| {
                    panic!("failed to parse {language_key} vector for entropy {entropy_hex}: {err}")
                });

                // Japanese's reference vectors join words with an ideographic
                // space (U+3000); the crate's `Display` always uses U+0020.
                let expected_phrase = phrase.replace('\u{3000}', " ");
                assert_eq!(mnemonic.phrase(), expected_phrase, "{language_key} entropy {entropy_hex}");
                assert_eq!(mnemonic.wordlist(), wordlist, "{language_key} entropy {entropy_hex}");
                let seed = mnemonic.to_seed("TREZOR".to_string());
                assert_eq!(
                    hex::encode(seed.export_raw()),
                    seed_hex,
                    "{language_key} entropy {entropy_hex}"
                );
            }
        }
    }
}
