//! Solana primitives: base58 address handling and program-derived-address
//! (PDA) computation. See `SolanaAddress.swift`, `SolanaProgram.swift`.

mod address;
mod pda;

pub use address::SolanaAddressFfi;
pub use pda::{solana_associated_token_address, solana_find_program_address, solana_metadata_address};
