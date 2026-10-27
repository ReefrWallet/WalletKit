//! CIP-30 dapp support for Cardano: fail-closed transaction decoding, signer
//! resolution, witness-only signing, CIP-8 data signing and CBOR codecs.
//!
//! Dapp transactions are arbitrary CBOR, so everything here works on the
//! original bytes (`FixedTransaction`) and never re-serializes a body: the
//! transaction hash a signer authorizes must be the one the dapp built.

mod cip8;
mod codec;
mod decode;
mod resolver;
mod signing;
#[cfg(test)]
mod tests;

pub(crate) use cip8::signature_structure;
pub use cip8::{
    cardano_cip8_assemble, cardano_cip8_sign_data, CardanoCip8Ffi,
};
pub use codec::{
    cardano_address_from_bytes, cardano_address_to_bytes, cardano_native_script_from_json, cardano_script_ref_native, cardano_script_ref_plutus,
    cardano_select_utxos, cardano_utxo_from_hex, cardano_utxo_to_hex, cardano_value_from_hex, cardano_value_to_hex,
    CardanoDappUtxoFfi, CardanoValueFfi,
};
pub use decode::{
    cardano_decode_transaction, cardano_transaction_hash, CardanoDappCertificateFfi, CardanoDappInputFfi,
    CardanoDappOutputFfi, CardanoDappTransactionFfi, CardanoDappWithdrawalFfi,
};
pub use resolver::{
    cardano_classify_signing_address, cardano_required_signers, CardanoResolvedOutputFfi, CardanoResolvedScriptFfi,
    CardanoSignersFfi, CardanoUsedIndicesFfi,
};
pub use signing::cardano_sign_dapp_transaction;
