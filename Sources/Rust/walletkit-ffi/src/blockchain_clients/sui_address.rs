//! `SuiAddressFfi`: a validated Sui address (32 raw bytes) — the
//! Blake2b-256 digest of a one-byte scheme flag followed by the account's
//! public key bytes. See
//! `Walletkit/Docs/Design Specification/Clients/Sui/SuiAddress.swift`.

use crate::errors::WalletKitErrorFfi;

#[derive(Debug, Clone, Copy, PartialEq, Eq, uniffi::Object)]
pub struct SuiAddressFfi {
    raw_bytes: [u8; 32],
}

impl SuiAddressFfi {
    pub(crate) fn from_raw(raw_bytes: [u8; 32]) -> SuiAddressFfi {
        SuiAddressFfi { raw_bytes }
    }
}

#[uniffi::export]
impl SuiAddressFfi {
    /// Wraps `raw_bytes` as a `SuiAddressFfi`. Throws `.invalidAddress` if
    /// `raw_bytes.len() != 32`.
    #[uniffi::constructor]
    pub fn new(raw_bytes: Vec<u8>) -> Result<SuiAddressFfi, WalletKitErrorFfi> {
        let array: [u8; 32] = raw_bytes.as_slice().try_into().map_err(|_| WalletKitErrorFfi::InvalidAddress {
            reason: format!("expected 32 raw bytes, got {}", raw_bytes.len()),
        })?;
        Ok(SuiAddressFfi { raw_bytes: array })
    }

    /// Parses `string` as a Sui address: `0x`-prefixed, 64 hex characters.
    /// Unlike Ethereum, Sui defines no checksum, so casing is never
    /// validated. Throws `.invalidAddress` for a missing `0x` prefix,
    /// wrong length, or non-hex characters.
    #[uniffi::constructor]
    pub fn from_string(string: String) -> Result<SuiAddressFfi, WalletKitErrorFfi> {
        let invalid = |reason: String| WalletKitErrorFfi::InvalidAddress { reason };
        let body = string.strip_prefix("0x").ok_or_else(|| invalid("missing 0x prefix".to_string()))?;
        if body.len() != 64 {
            return Err(invalid(format!("expected 64 hex characters, got {}", body.len())));
        }
        let bytes = hex::decode(body).map_err(|err| invalid(err.to_string()))?;
        let array: [u8; 32] = bytes.as_slice().try_into().expect("64 hex chars always decode to 32 bytes");
        Ok(SuiAddressFfi { raw_bytes: array })
    }

    pub fn raw_bytes(&self) -> Vec<u8> {
        self.raw_bytes.to_vec()
    }

    /// `0x`-prefixed, all-lowercase hex encoding.
    pub fn string(&self) -> String {
        format!("0x{}", hex::encode(self.raw_bytes))
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn new_rejects_the_wrong_byte_count() {
        assert!(matches!(SuiAddressFfi::new(vec![0u8; 31]), Err(WalletKitErrorFfi::InvalidAddress { .. })));
    }

    #[test]
    fn string_is_0x_prefixed_lowercase_hex() {
        let address = SuiAddressFfi::new(vec![0xabu8; 32]).unwrap();
        assert_eq!(address.string(), format!("0x{}", "ab".repeat(32)));
    }

    #[test]
    fn from_string_round_trips_through_new() {
        let raw: Vec<u8> = (0u8..32).collect();
        let address = SuiAddressFfi::new(raw.clone()).unwrap();
        let parsed = SuiAddressFfi::from_string(address.string()).unwrap();
        assert_eq!(parsed.raw_bytes(), raw);
    }

    #[test]
    fn from_string_accepts_mixed_case_since_sui_has_no_checksum() {
        let lower = format!("0x{}", "ab".repeat(32));
        let mixed = format!("0x{}", "Ab".repeat(32));
        let lower_parsed = SuiAddressFfi::from_string(lower).unwrap();
        let mixed_parsed = SuiAddressFfi::from_string(mixed).unwrap();
        assert_eq!(lower_parsed.raw_bytes(), mixed_parsed.raw_bytes());
    }

    #[test]
    fn from_string_rejects_missing_prefix() {
        let body = "ab".repeat(32);
        assert!(matches!(SuiAddressFfi::from_string(body), Err(WalletKitErrorFfi::InvalidAddress { .. })));
    }

    #[test]
    fn from_string_rejects_the_wrong_length() {
        assert!(matches!(
            SuiAddressFfi::from_string("0x1234".to_string()),
            Err(WalletKitErrorFfi::InvalidAddress { .. })
        ));
    }

    #[test]
    fn from_string_rejects_non_hex_characters() {
        let bad = format!("0x{}", "zz".repeat(32));
        assert!(matches!(SuiAddressFfi::from_string(bad), Err(WalletKitErrorFfi::InvalidAddress { .. })));
    }
}
