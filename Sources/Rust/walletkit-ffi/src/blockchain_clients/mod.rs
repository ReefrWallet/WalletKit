//! Blockchain-client extension points. See
//! `Walletkit/Docs/Design Specification/Clients/` for the target Swift
//! shape: `Signer`, `BlockchainAddress`, `EthereumPKeySigner`,
//! `EthereumTrezorSigner`, `EthereumAddress`, `SuiPKeySigner`, `SuiAddress`.
//! `EthereumSignerFfi`/`EthereumAddressFfi` and `SuiSignerFfi`/
//! `SuiAddressFfi` here are the Rust-side primitives-based
//! implementations that back those Swift signer/address types —
//! operating on `PublicKeyFfi`/`PrivateKeyFfi` rather than the Swift-only
//! `Account` type, since `Account` has no Rust representation.
//! `EthereumSignerFfi` additionally exposes `decode_signing_data`/
//! `signature`/`encode_signed` as the seam a hardware-backed signer (no
//! private key, a device instead) composes to reach the same signed
//! output as the software `sign` path. `SuiSignerFfi` covers address
//! derivation only, matching the Swift spec. `ethereum_function_selector`
//! is a standalone Keccak-256-based helper backing `EthereumABI.selector(_:)`
//! on the Swift side, for encoding arbitrary contract calls (ERC-20,
//! oracle reads, ...) rather than signing/address derivation. Every other
//! chain client remains design-only.

mod aptos_address;
mod aptos_signer;
pub mod bitcoin;
pub mod cardano;
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
    cardano_account_xpub_from_entropy, cardano_assemble_transaction, cardano_base_address, cardano_build_transfer,
    cardano_sign_transaction, cardano_stake_address, cardano_validate_address, CardanoAssetFfi,
    cardano_transaction_body_hash, CardanoWitnessFfi,
    CardanoProtocolParametersFfi, CardanoSigningPathFfi, CardanoTransactionInputFfi,
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
pub use sui_signer::SuiSignerFfi;
