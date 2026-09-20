//! `EthereumAddressFfi`: a validated Ethereum address (20 raw bytes),
//! backed by Alloy's `alloy_primitives::Address`. See
//! `Walletkit/Docs/Design Specification/Clients/EthereumAddress.swift`.

use alloy_primitives::Address as AlloyAddress;

use crate::errors::WalletKitErrorFfi;

#[derive(Debug, Clone, PartialEq, Eq, uniffi::Object)]
pub struct EthereumAddressFfi {
    inner: AlloyAddress,
}

impl EthereumAddressFfi {
    pub(crate) fn from_alloy(inner: AlloyAddress) -> EthereumAddressFfi {
        EthereumAddressFfi { inner }
    }
}

#[uniffi::export]
impl EthereumAddressFfi {
    /// Wraps `raw_bytes` as an `EthereumAddressFfi`. Throws `.invalidAddress`
    /// if `raw_bytes.len() != 20`.
    #[uniffi::constructor]
    pub fn new(raw_bytes: Vec<u8>) -> Result<EthereumAddressFfi, WalletKitErrorFfi> {
        let array: [u8; 20] = raw_bytes.as_slice().try_into().map_err(|_| WalletKitErrorFfi::InvalidAddress {
            reason: format!("expected 20 raw bytes, got {}", raw_bytes.len()),
        })?;
        Ok(EthereumAddressFfi { inner: AlloyAddress::from(array) })
    }

    /// Parses and validates `string` as an Ethereum address — `0x`-prefixed,
    /// 40 hex characters, either all one case (no checksum to validate) or
    /// held to its EIP-55 mixed-case checksum. Throws `.invalidAddress` for
    /// anything else, including a mixed-case string with the wrong
    /// checksum.
    #[uniffi::constructor]
    pub fn from_string(string: String) -> Result<EthereumAddressFfi, WalletKitErrorFfi> {
        let invalid = |reason: String| WalletKitErrorFfi::InvalidAddress { reason };
        let body = string.strip_prefix("0x").ok_or_else(|| invalid("missing 0x prefix".to_string()))?;
        if body.len() != 40 {
            return Err(invalid(format!("expected 40 hex characters, got {}", body.len())));
        }

        // All one case carries no checksum to validate; only a mixed-case
        // string is held to its EIP-55 checksum.
        let single_case = !body.chars().any(|c| c.is_ascii_uppercase()) || !body.chars().any(|c| c.is_ascii_lowercase());
        if single_case {
            string.parse::<AlloyAddress>().map(|inner| EthereumAddressFfi { inner }).map_err(|err| invalid(err.to_string()))
        } else {
            AlloyAddress::parse_checksummed(&string, None)
                .map(|inner| EthereumAddressFfi { inner })
                .map_err(|err| invalid(err.to_string()))
        }
    }

    pub fn raw_bytes(&self) -> Vec<u8> {
        self.inner.as_slice().to_vec()
    }

    /// EIP-55 mixed-case checksummed `0x`-prefixed hex encoding.
    pub fn string(&self) -> String {
        self.inner.to_checksum(None)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn vectors() -> Vec<(String, String, String)> {
        // (label, privateKey, address) — only `address` is used here; the
        // private keys are exercised by `ethereum_signer`'s tests instead.
        let raw = include_str!("../../../../../TestVectors/ethereum-address.json");
        let json: serde_json::Value = serde_json::from_str(raw).expect("ethereum-address.json is valid JSON");
        json.as_array()
            .expect("ethereum-address.json is a JSON array")
            .iter()
            .map(|entry| {
                (
                    entry["label"].as_str().unwrap().to_string(),
                    entry["privateKey"].as_str().unwrap().to_string(),
                    entry["address"].as_str().unwrap().to_string(),
                )
            })
            .collect()
    }

    #[test]
    fn from_string_round_trips_every_vectors_checksummed_address() {
        for (label, _private_key, address) in vectors() {
            let parsed =
                EthereumAddressFfi::from_string(address.clone()).unwrap_or_else(|err| panic!("{label}: {err}"));
            assert_eq!(parsed.string(), address, "{label}");
        }
    }

    #[test]
    fn from_string_accepts_all_lowercase_and_all_uppercase() {
        let checksummed = "0x9d8A62f656a8d1615C1294fd71e9CFb3E4855A4F";

        let lower = EthereumAddressFfi::from_string(checksummed.to_lowercase()).unwrap();
        assert_eq!(lower.string(), checksummed);

        let upper_body = checksummed.trim_start_matches("0x").to_uppercase();
        let upper = EthereumAddressFfi::from_string(format!("0x{upper_body}")).unwrap();
        assert_eq!(upper.string(), checksummed);
    }

    #[test]
    fn from_string_rejects_a_bad_checksum() {
        // One hex letter's case flipped ('A' -> 'a' right after the "0x9d8"
        // prefix) from an otherwise-valid checksummed address — the string
        // is still mixed-case, so checksum validation applies and must fail.
        let bad = "0x9d8a62f656a8d1615C1294fd71e9CFb3E4855A4F";
        assert!(matches!(
            EthereumAddressFfi::from_string(bad.to_string()),
            Err(WalletKitErrorFfi::InvalidAddress { .. })
        ));
    }

    #[test]
    fn from_string_rejects_the_wrong_length() {
        assert!(matches!(
            EthereumAddressFfi::from_string("0x1234".to_string()),
            Err(WalletKitErrorFfi::InvalidAddress { .. })
        ));
    }

    #[test]
    fn new_rejects_the_wrong_byte_count() {
        assert!(matches!(EthereumAddressFfi::new(vec![0u8; 19]), Err(WalletKitErrorFfi::InvalidAddress { .. })));
    }

    #[test]
    fn raw_bytes_round_trips_through_new() {
        for (label, _private_key, address) in vectors() {
            let parsed = EthereumAddressFfi::from_string(address.clone()).unwrap();
            let rebuilt = EthereumAddressFfi::new(parsed.raw_bytes()).unwrap();
            assert_eq!(rebuilt.string(), address, "{label}");
        }
    }
}
