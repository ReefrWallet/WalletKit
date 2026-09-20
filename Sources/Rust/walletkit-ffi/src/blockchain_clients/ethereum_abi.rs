//! Ethereum ABI helper utilities — function-selector computation
//! (`keccak256(signature)[0..4]`), reused by `EthereumABI.selector(_:)`
//! on the Swift side, and a raw Keccak-256 export, reused by
//! `EthereumENS.namehash(_:)` for ENS name resolution — so neither needs
//! to reimplement Keccak-256 outside Rust.

use alloy_primitives::keccak256;

/// Computes the 4-byte Solidity/Vyper function selector for `signature`
/// (e.g. `"balanceOf(address)"`), Keccak-256(signature)'s first 4 bytes.
///
/// - Parameter signature: The canonical function signature — name plus
///   parenthesized, comma-separated parameter types, no parameter names
///   or spaces (e.g. `"transfer(address,uint256)"`).
/// - Returns: The 4-byte selector.
#[uniffi::export]
pub fn ethereum_function_selector(signature: String) -> Vec<u8> {
    keccak256(signature.as_bytes())[0..4].to_vec()
}

/// Computes the 32-byte Keccak-256 hash of `data`.
///
/// - Parameter data: The bytes to hash.
/// - Returns: The 32-byte hash.
#[uniffi::export]
pub fn ethereum_keccak256(data: Vec<u8>) -> Vec<u8> {
    keccak256(data).to_vec()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn balance_of_selector_matches_the_well_known_value() {
        assert_eq!(ethereum_function_selector("balanceOf(address)".to_string()), vec![0x70, 0xa0, 0x82, 0x31]);
    }

    #[test]
    fn transfer_selector_matches_the_well_known_value() {
        assert_eq!(
            ethereum_function_selector("transfer(address,uint256)".to_string()),
            vec![0xa9, 0x05, 0x9c, 0xbb]
        );
    }

    #[test]
    fn latest_round_data_selector_matches_the_well_known_value() {
        assert_eq!(ethereum_function_selector("latestRoundData()".to_string()), vec![0xfe, 0xaf, 0x96, 0x8c]);
    }

    #[test]
    fn decimals_selector_matches_the_well_known_value() {
        assert_eq!(ethereum_function_selector("decimals()".to_string()), vec![0x31, 0x3c, 0xe5, 0x67]);
    }

    #[test]
    fn different_signatures_produce_different_selectors() {
        assert_ne!(
            ethereum_function_selector("balanceOf(address)".to_string()),
            ethereum_function_selector("transfer(address,uint256)".to_string())
        );
    }

    #[test]
    fn keccak256_of_empty_input_matches_the_well_known_value() {
        assert_eq!(
            ethereum_keccak256(Vec::new()),
            hex::decode("c5d2460186f7233c927e7db2dcc703c0e500b653ca82273b7bfad8045d85a470").unwrap()
        );
    }

    #[test]
    fn keccak256_of_different_inputs_differ() {
        assert_ne!(ethereum_keccak256(b"eth".to_vec()), ethereum_keccak256(b"usd".to_vec()));
    }
}

