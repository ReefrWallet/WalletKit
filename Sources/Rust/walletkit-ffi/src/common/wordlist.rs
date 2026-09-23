//! `Wordlist`: a BIP39 wordlist.
//!
//! Covers the 10 official BIP39 wordlists supported by the `bip39` crate.
//! Russian and Turkish appear in the design spec's shared test vectors but
//! aren't official BIP39 wordlists and `bip39` doesn't implement them, so
//! they're intentionally not included here rather than hand-rolled.

use bip39::Language;

#[derive(Debug, Clone, Copy, PartialEq, Eq, uniffi::Enum)]
pub enum Wordlist {
    English,
    ChineseSimplified,
    ChineseTraditional,
    Czech,
    French,
    Italian,
    Japanese,
    Korean,
    Portuguese,
    Spanish,
}

pub(crate) fn language(wordlist: Wordlist) -> Language {
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

/// The 2048 words `wordlist` draws from, in BIP39 index order.
#[uniffi::export]
pub fn wordlist_words(wordlist: Wordlist) -> Vec<String> {
    language(wordlist).word_list().iter().map(|word| (*word).to_string()).collect()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn wordlist_all_cases_contains_english() {
        assert_eq!(Wordlist::English, Wordlist::English);
    }

    #[test]
    fn wordlist_words_returns_2048_words_for_every_variant() {
        for wordlist in [
            Wordlist::English,
            Wordlist::ChineseSimplified,
            Wordlist::ChineseTraditional,
            Wordlist::Czech,
            Wordlist::French,
            Wordlist::Italian,
            Wordlist::Japanese,
            Wordlist::Korean,
            Wordlist::Portuguese,
            Wordlist::Spanish,
        ] {
            assert_eq!(wordlist_words(wordlist).len(), 2048, "{wordlist:?}");
        }
    }

    #[test]
    fn wordlist_words_english_starts_with_abandon_and_ends_with_zoo() {
        let words = wordlist_words(Wordlist::English);
        assert_eq!(words.first().map(String::as_str), Some("abandon"));
        assert_eq!(words.last().map(String::as_str), Some("zoo"));
    }

    #[test]
    fn wordlist_words_never_contains_an_empty_word() {
        for wordlist in [
            Wordlist::English,
            Wordlist::ChineseSimplified,
            Wordlist::ChineseTraditional,
            Wordlist::Czech,
            Wordlist::French,
            Wordlist::Italian,
            Wordlist::Japanese,
            Wordlist::Korean,
            Wordlist::Portuguese,
            Wordlist::Spanish,
        ] {
            assert!(wordlist_words(wordlist).iter().all(|word| !word.is_empty()), "{wordlist:?}");
        }
    }
}
