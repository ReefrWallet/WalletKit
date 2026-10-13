//! `BlockchainFfi`: a chain identifier, one case per supported chain. Carries
//! no derivation-path logic of its own — an `Account`'s curve and
//! derivation path are tracked directly on `Account` instead. Some cases
//! carry the extra configuration a `Signer` needs beyond the identifier
//! itself: `Ethereum` carries its EVM chain ID. See
//! `Walletkit/Docs/Design Specification/Core/Blockchain.swift`.

#[derive(Debug, Clone, Copy, PartialEq, Eq, uniffi::Enum)]
pub enum BlockchainFfi {
    Aptos,
    Bitcoin,
    Ethereum(u64),
    Tron,
    Solana,
    Cardano,
    Sui,
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn blockchain_cases_are_distinct() {
        assert_ne!(BlockchainFfi::Bitcoin, BlockchainFfi::Ethereum(1));
    }

    #[test]
    fn ethereum_variants_compare_by_chain_id() {
        assert_eq!(BlockchainFfi::Ethereum(1), BlockchainFfi::Ethereum(1));
        assert_ne!(BlockchainFfi::Ethereum(1), BlockchainFfi::Ethereum(11_155_111));
    }

    #[test]
    fn aptos_case_is_distinct_from_others() {
        assert_ne!(BlockchainFfi::Aptos, BlockchainFfi::Sui);
    }

    #[test]
    fn sui_case_is_distinct_from_others() {
        assert_ne!(BlockchainFfi::Sui, BlockchainFfi::Bitcoin);
    }
}
