//! `MnemonicWordCount`: BIP39 word counts a mnemonic may have.

#[derive(Debug, Clone, Copy, PartialEq, Eq, uniffi::Enum)]
pub enum MnemonicWordCount {
    Words12 = 12,
    Words15 = 15,
    Words18 = 18,
    Words21 = 21,
    Words24 = 24,
}

impl MnemonicWordCount {
    pub const ALL: [MnemonicWordCount; 5] = [
        MnemonicWordCount::Words12,
        MnemonicWordCount::Words15,
        MnemonicWordCount::Words18,
        MnemonicWordCount::Words21,
        MnemonicWordCount::Words24,
    ];

    pub fn from_word_count(count: usize) -> Option<Self> {
        match count {
            12 => Some(Self::Words12),
            15 => Some(Self::Words15),
            18 => Some(Self::Words18),
            21 => Some(Self::Words21),
            24 => Some(Self::Words24),
            _ => None,
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn mnemonic_word_count_all_cases_have_the_expected_raw_values() {
        let raw_values: Vec<u32> = MnemonicWordCount::ALL.iter().map(|c| *c as u32).collect();
        assert_eq!(raw_values, vec![12, 15, 18, 21, 24]);
    }
}
