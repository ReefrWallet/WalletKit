//! Program-derived-address (PDA) computation for Solana — the
//! `find_program_address` algorithm plus the two PDA derivations
//! WalletKit needs directly: a wallet's associated token account (ATA)
//! and a mint's Metaplex Token Metadata account. See
//! `Walletkit/Docs/Design Specification/Clients/Solana/SolanaProgram.swift`.

use sha2::{Digest, Sha256};

use crate::errors::WalletKitErrorFfi;

use super::address::SolanaAddressFfi;

/// SPL Associated Token Account program — `ATokenGPvbdGVxr1b2hvZbsiqW5xWH25efTNsLJA8knL`.
const ASSOCIATED_TOKEN_PROGRAM_ID: &str = "ATokenGPvbdGVxr1b2hvZbsiqW5xWH25efTNsLJA8knL";

/// Metaplex Token Metadata program — `metaqbxxUerdq28cj1RbAWkYQm3ybzjb6a8bt518x1s`.
const TOKEN_METADATA_PROGRAM_ID: &str = "metaqbxxUerdq28cj1RbAWkYQm3ybzjb6a8bt518x1s";

fn decode_address(base58: &str) -> [u8; 32] {
    bs58::decode(base58)
        .into_vec()
        .expect("hardcoded program id is valid base58")
        .try_into()
        .expect("hardcoded program id decodes to 32 bytes")
}

/// Derives the canonical program-derived address for `seeds` under
/// `program_id`: the highest bump seed (starting at 255, going down) for
/// which `sha256(seeds || bump || program_id || "ProgramDerivedAddress")`
/// is *not* a valid ed25519 curve point — PDAs are deliberately
/// off-curve, so no private key can ever exist for one.
///
/// - Parameters:
///   - seeds: Up to 16 seed byte strings, each at most 32 bytes (Solana's
///     own limits), concatenated in order.
///   - program_id: The 32-byte program address seeds are derived under.
/// - Returns: The PDA's 32 raw bytes.
/// - Throws: `.internalError` if every bump from 255 down to 0 lands
///   on-curve (astronomically unlikely) or a seed exceeds 32 bytes.
#[uniffi::export]
pub fn solana_find_program_address(
    seeds: Vec<Vec<u8>>,
    program_id: Vec<u8>,
) -> Result<Vec<u8>, WalletKitErrorFfi> {
    for seed in &seeds {
        if seed.len() > 32 {
            return Err(WalletKitErrorFfi::InternalError {
                message: format!("PDA seed exceeds 32 bytes: {} bytes", seed.len()),
            });
        }
    }

    for bump in (0u8..=255).rev() {
        let mut hasher = Sha256::new();
        for seed in &seeds {
            hasher.update(seed);
        }
        hasher.update([bump]);
        hasher.update(&program_id);
        hasher.update(b"ProgramDerivedAddress");
        let digest: [u8; 32] = hasher.finalize().into();

        if SolanaAddressFfi::from_raw(digest).is_on_curve() {
            continue;
        }

        return Ok(digest.to_vec());
    }

    Err(WalletKitErrorFfi::InternalError { message: "no off-curve PDA bump found for these seeds".to_string() })
}

/// Derives `owner`'s associated token account (ATA) for `mint` under
/// `token_program` (the classic SPL Token program or Token-2022) — the
/// PDA of `[owner, token_program, mint]` under the Associated Token
/// Account program.
///
/// - Parameters:
///   - owner: The wallet address the ATA belongs to.
///   - mint: The token mint address.
///   - token_program: The token program the mint belongs to (SPL Token
///     or Token-2022's address).
/// - Returns: The ATA's 32 raw bytes.
#[uniffi::export]
pub fn solana_associated_token_address(
    owner: Vec<u8>,
    mint: Vec<u8>,
    token_program: Vec<u8>,
) -> Result<Vec<u8>, WalletKitErrorFfi> {
    solana_find_program_address(vec![owner, token_program, mint], decode_address(ASSOCIATED_TOKEN_PROGRAM_ID).to_vec())
}

/// Derives `mint`'s Metaplex Token Metadata account — the PDA of
/// `["metadata", tokenMetadataProgram, mint]` under the Token Metadata
/// program.
///
/// - Parameter mint: The token mint address.
/// - Returns: The metadata account's 32 raw bytes.
#[uniffi::export]
pub fn solana_metadata_address(mint: Vec<u8>) -> Result<Vec<u8>, WalletKitErrorFfi> {
    let program_id = decode_address(TOKEN_METADATA_PROGRAM_ID).to_vec();
    solana_find_program_address(vec![b"metadata".to_vec(), program_id.clone(), mint], program_id)
}

#[cfg(test)]
mod tests {
    use super::*;

    /// USDC mint on mainnet — chosen because its ATA for a well-known
    /// owner is independently verifiable via any Solana explorer.
    const USDC_MINT: &str = "EPjFWdd5AufqSSqeM2qN1xzybapC8G4wEGGkZwyTDt1v";

    fn decode(base58: &str) -> Vec<u8> {
        bs58::decode(base58).into_vec().unwrap()
    }

    #[test]
    fn find_program_address_is_deterministic() {
        let seeds = vec![b"seed-one".to_vec(), b"seed-two".to_vec()];
        let program_id = decode_address(ASSOCIATED_TOKEN_PROGRAM_ID).to_vec();
        let first = solana_find_program_address(seeds.clone(), program_id.clone()).unwrap();
        let second = solana_find_program_address(seeds, program_id).unwrap();
        assert_eq!(first, second);
    }

    #[test]
    fn find_program_address_result_is_off_curve() {
        let seeds = vec![b"any-seed".to_vec()];
        let program_id = decode_address(TOKEN_METADATA_PROGRAM_ID).to_vec();
        let pda = solana_find_program_address(seeds, program_id).unwrap();
        let array: [u8; 32] = pda.try_into().unwrap();
        assert!(!SolanaAddressFfi::from_raw(array).is_on_curve());
    }

    #[test]
    fn find_program_address_rejects_an_oversized_seed() {
        let seeds = vec![vec![0u8; 33]];
        let program_id = decode_address(ASSOCIATED_TOKEN_PROGRAM_ID).to_vec();
        assert!(matches!(
            solana_find_program_address(seeds, program_id),
            Err(WalletKitErrorFfi::InternalError { .. })
        ));
    }

    #[test]
    fn associated_token_address_matches_an_independently_computed_vector() {
        // Cross-checked with a standalone Python script (sha256 + PyNaCl's
        // `crypto_core_ed25519_is_valid_point` for the off-curve bump
        // search) against real mainnet program/mint addresses; `owner`
        // is an arbitrary well-formed ed25519 public key, not tied to any
        // real wallet.
        let owner = decode("H8sMJSCQxfKiFTCfDR3DUMLPwcRbM61LGFJ8N4dK3WjS");
        let expected_ata = decode("7dQmths1cyCQ4xaC5KcVfXz4BvVWtnHc3hcgnfnE1PBx");
        let token_program = decode("TokenkegQfeZyiNwAJbNbGKPFXCWuBvf9Ss623VQ5DA");

        let ata = solana_associated_token_address(owner, decode(USDC_MINT), token_program).unwrap();
        assert_eq!(ata, expected_ata);
    }

    #[test]
    fn metadata_address_matches_an_independently_computed_vector() {
        // Cross-checked the same way as the ATA vector above, using
        // USDC's real mainnet mint and the real Token Metadata program.
        let expected_metadata = decode("5x38Kp4hvdomTCnCrAny4UtMUt5rQBdB6px2K1Ui45Wq");
        let metadata = solana_metadata_address(decode(USDC_MINT)).unwrap();
        assert_eq!(metadata, expected_metadata);
    }
}
