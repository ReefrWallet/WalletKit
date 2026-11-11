//! Address, transaction, and signing primitives for Swift blockchain clients.
//! `EthereumSignerFfi` exposes transaction decoding and signature assembly
//! for hardware signing. `SuiSignerFfi` derives addresses and signs
//! transactions and personal messages.

mod aptos_address;
mod aptos_signer;
pub mod bitcoin;
pub mod cardano;
pub mod cardano_dapp;
mod ethereum_abi;
mod ethereum_address;
mod ethereum_message;
mod ethereum_signer;
pub mod solana;
mod sui_address;
mod sui_signer;

pub use aptos_address::AptosAddressFfi;
pub use aptos_signer::{aptos_transaction_hash, AptosSignerFfi};
pub use bitcoin::{
    bitcoin_build_unsigned_psbt, bitcoin_decode_transaction, bitcoin_estimate_vsize, bitcoin_fingerprint,
    bitcoin_psbt_fee, bitcoin_psbt_input_derivations, BitcoinAddressFfi, BitcoinDecodedInputFfi,
    BitcoinDecodedOutputFfi, BitcoinDecodedTransactionFfi, BitcoinDescriptorFfi, BitcoinInputKindFfi,
    BitcoinNetworkFfi, BitcoinPsbtInputDerivationFfi, BitcoinPsbtInputFfi, BitcoinPsbtOutputFfi, BitcoinScriptTypeFfi,
    BitcoinSignerFfi,
};
pub use cardano::{
    cardano_account_xpub, cardano_assemble_transaction, cardano_base_address, cardano_build_transfer,
    cardano_sign_transaction, cardano_stake_address, cardano_validate_address, CardanoAssetFfi,
    cardano_transaction_body_hash, CardanoWitnessFfi,
    CardanoProtocolParametersFfi, CardanoRootSecretFfi, CardanoSigningPathFfi, CardanoTransactionInputFfi,
    CardanoTransactionOutputFfi, CardanoUnsignedTransactionFfi, CardanoUtxoFfi,
};
pub use ethereum_abi::{ethereum_function_selector, ethereum_keccak256};
pub use ethereum_address::EthereumAddressFfi;
pub use ethereum_message::{
    ethereum_personal_message_hash, ethereum_typed_data_fields, ethereum_typed_data_hash, EthereumTypedDataFieldsFfi,
};
pub use ethereum_signer::{
    EthereumEIP1559SignTxFfi, EthereumEIP1559SignatureFfi,
    EthereumSignTxFfi, EthereumSignatureFfi, EthereumSignerFfi,
};
pub use solana::{solana_associated_token_address, solana_find_program_address, solana_metadata_address, SolanaAddressFfi};
pub use sui_address::SuiAddressFfi;
pub use sui_signer::{blake2b256, SuiSignerFfi};
