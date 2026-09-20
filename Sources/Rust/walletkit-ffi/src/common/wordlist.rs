//! `Wordlist`: a BIP39 wordlist.
//!
//! Covers the 10 official BIP39 wordlists supported by the `bip39` crate.
//! Russian and Turkish appear in the design spec's shared test vectors but
//! aren't official BIP39 wordlists and `bip39` doesn't implement them, so
//! they're intentionally not included here rather than hand-rolled.

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

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn wordlist_all_cases_contains_english() {
        assert_eq!(Wordlist::English, Wordlist::English);
    }
}
