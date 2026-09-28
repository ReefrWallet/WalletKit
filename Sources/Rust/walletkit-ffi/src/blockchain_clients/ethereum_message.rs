//! EIP-191 personal-message hashing and EIP-712 typed-data hashing for
//! Ethereum's `personal_sign`/`eth_signTypedData_v4`, backed by Alloy
//! (`alloy-primitives`'s `eip191_hash_message`, `alloy-dyn-abi`'s
//! `TypedData`) rather than hand-rolled hashing. See
//! `Walletkit/Docs/Design Specification/Clients/EthereumSigner.swift`.
//!
//! `ethereum_typed_data_fields` deliberately re-serializes the input
//! JSON's own `types`/`domain`/`message` sub-objects verbatim rather than
//! walking `TypedData`'s internal type resolver — a hardware device
//! driver needs exactly the wire-format struct definitions to drive its
//! own `EthereumTypedDataStructRequest`/`EthereumTypedDataValueRequest`
//! exchange, not `alloy-dyn-abi`'s resolved representation of them.

use std::sync::Arc;

use alloy_dyn_abi::TypedData;
use alloy_primitives::eip191_hash_message;

use crate::common::CurveFfi;
use crate::errors::WalletKitErrorFfi;
use crate::keys::PrivateKeyFfi;

use super::ethereum_signer::EthereumSignerFfi;

/// The structured fields of an EIP-712 typed-data payload a hardware
/// device's trusted screen needs to step through an `EthereumSignTypedData`
/// interaction — the `types`/`domain`/`message` sub-objects verbatim as
/// JSON, plus the two hashes that combine into `eip712_signing_hash`
/// (`domain_separator_hash`, `message_hash`), which Trezor firmware wants
/// directly for its `EthereumSignTypedHash` fallback (Trezor One).
#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct EthereumTypedDataFieldsFfi {
    pub primary_type: String,
    pub types_json: String,
    pub domain_json: String,
    pub message_json: String,
    pub domain_separator_hash: Vec<u8>,
    pub message_hash: Vec<u8>,
}

/// Computes the EIP-191 personal-message hash —
/// `keccak256("\x19Ethereum Signed Message:\n" + len(message) + message)`
/// — that `personal_sign` signs.
///
/// - Parameter message: The raw message bytes (not yet hashed or prefixed).
/// - Returns: The 32-byte hash.
#[uniffi::export]
pub fn ethereum_personal_message_hash(message: Vec<u8>) -> Vec<u8> {
    eip191_hash_message(&message).0.to_vec()
}

/// Computes the EIP-712 signing hash `eth_signTypedData_v4` signs —
/// `keccak256(0x1901 || domainSeparator || hashStruct(message))`.
///
/// - Parameter json: The typed-data payload as JSON, in the same shape
///   `eth_signTypedData_v4` receives it (`types`, `primaryType`,
///   `domain`, `message`).
/// - Returns: The 32-byte hash.
///
/// Throws `.signingFailed` if `json` isn't a well-formed EIP-712
/// typed-data payload.
#[uniffi::export]
pub fn ethereum_typed_data_hash(json: String) -> Result<Vec<u8>, WalletKitErrorFfi> {
    let typed_data = parse_typed_data(&json)?;
    typed_data.eip712_signing_hash().map(|hash| hash.0.to_vec()).map_err(|err| WalletKitErrorFfi::SigningFailed {
        reason: format!("failed to compute EIP-712 signing hash: {err}"),
    })
}

/// Decodes `json` into the fields a hardware device's trusted screen
/// needs — see `EthereumTypedDataFieldsFfi`.
///
/// Throws `.signingFailed` if `json` isn't a well-formed EIP-712
/// typed-data payload, or is missing its top-level `types`/`domain`/
/// `message` object.
#[uniffi::export]
pub fn ethereum_typed_data_fields(json: String) -> Result<EthereumTypedDataFieldsFfi, WalletKitErrorFfi> {
    let typed_data = parse_typed_data(&json)?;
    let domain_separator_hash = typed_data.domain().separator().0.to_vec();
    let message_hash = typed_data.hash_struct().map(|hash| hash.0.to_vec()).map_err(|err| {
        WalletKitErrorFfi::SigningFailed { reason: format!("failed to compute EIP-712 message hash: {err}") }
    })?;

    let raw: serde_json::Value = serde_json::from_str(&json)
        .map_err(|err| WalletKitErrorFfi::SigningFailed { reason: format!("invalid typed-data JSON: {err}") })?;
    let sub_object_json = |key: &str| -> Result<String, WalletKitErrorFfi> {
        let value = raw.get(key).ok_or_else(|| WalletKitErrorFfi::SigningFailed {
            reason: format!("typed-data JSON is missing `{key}`"),
        })?;
        serde_json::to_string(value)
            .map_err(|err| WalletKitErrorFfi::SigningFailed { reason: format!("failed to re-encode `{key}`: {err}") })
    };

    Ok(EthereumTypedDataFieldsFfi {
        primary_type: typed_data.primary_type.clone(),
        types_json: sub_object_json("types")?,
        domain_json: sub_object_json("domain")?,
        message_json: sub_object_json("message")?,
        domain_separator_hash,
        message_hash,
    })
}

fn parse_typed_data(json: &str) -> Result<TypedData, WalletKitErrorFfi> {
    serde_json::from_str(json)
        .map_err(|err| WalletKitErrorFfi::SigningFailed { reason: format!("invalid EIP-712 typed-data JSON: {err}") })
}

#[uniffi::export]
impl EthereumSignerFfi {
    /// Signs an already-hashed 32-byte digest — the EIP-191
    /// personal-message hash or the EIP-712 signing hash — with
    /// `private_key`, returning the 65-byte `r ‖ s ‖ v` signature
    /// `personal_sign`/`eth_signTypedData_v4` return, where `v` is folded
    /// to Ethereum's legacy 27/28 (not EIP-155's `chainId * 2 + 35`,
    /// which only applies to transactions).
    ///
    /// Throws `.unsupportedCurve` for a non-secp256k1 key, or
    /// `.signingFailed` if `digest` isn't 32 bytes.
    pub fn sign_digest(&self, digest: Vec<u8>, private_key: Arc<PrivateKeyFfi>) -> Result<Vec<u8>, WalletKitErrorFfi> {
        if private_key.curve() != CurveFfi::Secp256k1 {
            return Err(WalletKitErrorFfi::UnsupportedCurve { curve: private_key.curve() });
        }

        let signature = private_key.sign_prehashed_recoverable(digest)?;
        if signature.compact.len() != 64 {
            return Err(WalletKitErrorFfi::SigningFailed {
                reason: format!("expected a 64-byte compact signature, got {}", signature.compact.len()),
            });
        }

        let mut out = signature.compact;
        out.push(27 + signature.recovery_id);
        Ok(out)
    }
}

#[cfg(test)]
mod tests {
    use std::sync::Arc;

    use super::*;

    /// The worked "Mail" example from the EIP-712 spec itself
    /// (eips.ethereum.org/EIPS/eip-712#example), whose signing hash is
    /// quoted verbatim in the spec as
    /// `0xbe609aee343fb3c4b28e1df9e632fca64fcfaede20f02e86244efddf30957bd2`.
    const EIP_712_MAIL_EXAMPLE: &str = r#"{
        "types": {
            "EIP712Domain": [
                {"name": "name", "type": "string"},
                {"name": "version", "type": "string"},
                {"name": "chainId", "type": "uint256"},
                {"name": "verifyingContract", "type": "address"}
            ],
            "Person": [
                {"name": "name", "type": "string"},
                {"name": "wallet", "type": "address"}
            ],
            "Mail": [
                {"name": "from", "type": "Person"},
                {"name": "to", "type": "Person"},
                {"name": "contents", "type": "string"}
            ]
        },
        "primaryType": "Mail",
        "domain": {
            "name": "Ether Mail",
            "version": "1",
            "chainId": 1,
            "verifyingContract": "0xCcCCccccCCCCcCCCCCCcCcCccCcCCCcCcccccccC"
        },
        "message": {
            "from": {"name": "Cow", "wallet": "0xCD2a3d9F938E13CD947Ec05AbC7FE734Df8DD826"},
            "to": {"name": "Bob", "wallet": "0xbBbBBBBbbBBBbbbBbbBbbbbBBbBbbbbBbBbbBBbB"},
            "contents": "Hello, Bob!"
        }
    }"#;

    #[test]
    fn personal_message_hash_matches_the_eip_191_formula() {
        let message = b"Example personal_sign message".to_vec();
        let prefix = format!("\x19Ethereum Signed Message:\n{}", message.len());
        let mut preimage = prefix.into_bytes();
        preimage.extend_from_slice(&message);
        let expected = alloy_primitives::keccak256(&preimage).0.to_vec();
        assert_eq!(ethereum_personal_message_hash(message), expected);
    }

    #[test]
    fn typed_data_hash_matches_the_eip_712_spec_mail_example() {
        let hash = ethereum_typed_data_hash(EIP_712_MAIL_EXAMPLE.to_string()).unwrap();
        assert_eq!(hex::encode(hash), "be609aee343fb3c4b28e1df9e632fca64fcfaede20f02e86244efddf30957bd2");
    }

    #[test]
    fn typed_data_hash_rejects_malformed_json() {
        assert!(matches!(
            ethereum_typed_data_hash("not json".to_string()),
            Err(WalletKitErrorFfi::SigningFailed { .. })
        ));
    }

    #[test]
    fn typed_data_fields_carries_the_verbatim_sub_objects_and_matching_hashes() {
        let fields = ethereum_typed_data_fields(EIP_712_MAIL_EXAMPLE.to_string()).unwrap();
        assert_eq!(fields.primary_type, "Mail");

        let domain: serde_json::Value = serde_json::from_str(&fields.domain_json).unwrap();
        assert_eq!(domain["name"], "Ether Mail");
        let message: serde_json::Value = serde_json::from_str(&fields.message_json).unwrap();
        assert_eq!(message["contents"], "Hello, Bob!");
        let types: serde_json::Value = serde_json::from_str(&fields.types_json).unwrap();
        assert!(types.get("Person").is_some());

        // domain_separator_hash and message_hash must combine into the
        // same signing hash `ethereum_typed_data_hash` computes directly.
        let mut preimage = vec![0x19, 0x01];
        preimage.extend_from_slice(&fields.domain_separator_hash);
        preimage.extend_from_slice(&fields.message_hash);
        let recombined = alloy_primitives::keccak256(&preimage).0.to_vec();
        assert_eq!(recombined, ethereum_typed_data_hash(EIP_712_MAIL_EXAMPLE.to_string()).unwrap());
    }

    #[test]
    fn sign_digest_returns_a_65_byte_signature_with_legacy_v() {
        let private_key = Arc::new(PrivateKeyFfi::from_raw_bytes(CurveFfi::Secp256k1, vec![7u8; 32]).unwrap());
        let signer = EthereumSignerFfi::new(1);
        let digest = ethereum_personal_message_hash(b"hello reefr".to_vec());
        let signature = signer.sign_digest(digest, private_key).unwrap();
        assert_eq!(signature.len(), 65);
        assert!(signature[64] == 27 || signature[64] == 28);
    }

    #[test]
    fn sign_digest_rejects_an_ed25519_key() {
        let private_key = Arc::new(PrivateKeyFfi::new(CurveFfi::Ed25519, [7u8; 32]));
        let signer = EthereumSignerFfi::new(1);
        assert!(matches!(
            signer.sign_digest(vec![0u8; 32], private_key),
            Err(WalletKitErrorFfi::UnsupportedCurve { curve: CurveFfi::Ed25519 })
        ));
    }

    #[test]
    fn sign_digest_rejects_a_malformed_digest() {
        let private_key = Arc::new(PrivateKeyFfi::from_raw_bytes(CurveFfi::Secp256k1, vec![7u8; 32]).unwrap());
        let signer = EthereumSignerFfi::new(1);
        assert!(matches!(
            signer.sign_digest(vec![0u8; 31], private_key),
            Err(WalletKitErrorFfi::SigningFailed { .. })
        ));
    }
}
