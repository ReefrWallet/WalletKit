//! `AptosAddressFfi`: a validated Aptos account address (32 raw bytes).

use crate::errors::WalletKitErrorFfi;

#[derive(Debug, Clone, Copy, PartialEq, Eq, uniffi::Object)]
pub struct AptosAddressFfi {
    raw_bytes: [u8; 32],
}

impl AptosAddressFfi {
    pub(crate) fn from_raw(raw_bytes: [u8; 32]) -> AptosAddressFfi {
        AptosAddressFfi { raw_bytes }
    }

    /// AIP-40 special address: first 31 bytes zero, last byte < 0x10.
    fn is_special(&self) -> bool {
        self.raw_bytes[..31].iter().all(|byte| *byte == 0) && self.raw_bytes[31] < 0x10
    }
}

#[uniffi::export]
impl AptosAddressFfi {
    /// Throws `.invalidAddress` if `raw_bytes.len() != 32`.
    #[uniffi::constructor]
    pub fn new(raw_bytes: Vec<u8>) -> Result<AptosAddressFfi, WalletKitErrorFfi> {
        let array: [u8; 32] = raw_bytes.as_slice().try_into().map_err(|_| WalletKitErrorFfi::InvalidAddress {
            reason: format!("expected 32 raw bytes, got {}", raw_bytes.len()),
        })?;
        Ok(AptosAddressFfi { raw_bytes: array })
    }

    /// Parses AIP-40 strict form: `0x` plus 64 hex characters, or the short
    /// form (`0x0`–`0xf`) for special addresses only. Padding other short
    /// strings is refused: a truncated paste would silently name another
    /// account.
    #[uniffi::constructor]
    pub fn from_string(string: String) -> Result<AptosAddressFfi, WalletKitErrorFfi> {
        let invalid = |reason: String| WalletKitErrorFfi::InvalidAddress { reason };
        let body = string.strip_prefix("0x").ok_or_else(|| invalid("missing 0x prefix".to_string()))?;
        if body.len() == 1 {
            let value = u8::from_str_radix(body, 16).map_err(|err| invalid(err.to_string()))?;
            let mut raw_bytes = [0u8; 32];
            raw_bytes[31] = value;
            return Ok(AptosAddressFfi { raw_bytes });
        }
        if body.len() != 64 {
            return Err(invalid(format!("expected 64 hex characters, got {}", body.len())));
        }
        let bytes = hex::decode(body).map_err(|err| invalid(err.to_string()))?;
        let array: [u8; 32] = bytes.as_slice().try_into().expect("64 hex chars always decode to 32 bytes");
        Ok(AptosAddressFfi { raw_bytes: array })
    }

    /// Parses any `0x`-prefixed hex of 1–64 characters, left-padding with
    /// zeros. For chain-reported addresses only (node REST strips leading
    /// zeros); user input goes through `from_string`.
    #[uniffi::constructor]
    pub fn from_string_relaxed(string: String) -> Result<AptosAddressFfi, WalletKitErrorFfi> {
        let invalid = |reason: String| WalletKitErrorFfi::InvalidAddress { reason };
        let body = string.strip_prefix("0x").ok_or_else(|| invalid("missing 0x prefix".to_string()))?;
        if body.is_empty() || body.len() > 64 {
            return Err(invalid(format!("expected 1–64 hex characters, got {}", body.len())));
        }
        AptosAddressFfi::from_string(format!("0x{body:0>64}"))
    }

    pub fn raw_bytes(&self) -> Vec<u8> {
        self.raw_bytes.to_vec()
    }

    /// AIP-40 display form: `0x1` for special addresses, otherwise `0x` plus
    /// 64 lowercase hex characters.
    pub fn string(&self) -> String {
        if self.is_special() {
            format!("0x{:x}", self.raw_bytes[31])
        } else {
            self.string_long()
        }
    }

    /// `0x` plus 64 lowercase hex characters, for every address.
    pub fn string_long(&self) -> String {
        format!("0x{}", hex::encode(self.raw_bytes))
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn parse(string: &str) -> Result<AptosAddressFfi, WalletKitErrorFfi> {
        AptosAddressFfi::from_string(string.to_string())
    }

    #[test]
    fn long_form_round_trips() {
        let string = format!("0x{}", "ab".repeat(32));
        assert_eq!(parse(&string).unwrap().string(), string);
    }

    #[test]
    fn special_addresses_use_the_short_form() {
        let one = parse("0x1").unwrap();
        assert_eq!(one.string(), "0x1");
        assert_eq!(one.string_long(), format!("0x{}1", "0".repeat(63)));
        assert_eq!(parse(&one.string_long()).unwrap(), one);
        assert_eq!(parse("0xa").unwrap().string(), "0xa");
    }

    #[test]
    fn rejects_padded_non_special_short_forms() {
        assert!(parse("0x10").is_err());
        assert!(parse(&format!("0x{}", "ab".repeat(31))).is_err());
    }

    #[test]
    fn relaxed_parsing_pads_chain_reported_addresses() {
        let short = "0x6d678a7c9c2eed7f20391459d1aec5d7f532710e6455f145bf2dc790b9d2c02";
        let parsed = AptosAddressFfi::from_string_relaxed(short.to_string()).unwrap();
        assert_eq!(parsed.string(), format!("0x0{}", &short[2..]));
        assert!(AptosAddressFfi::from_string_relaxed("0x".to_string()).is_err());
        assert!(AptosAddressFfi::from_string_relaxed(format!("0x{}", "1".repeat(65))).is_err());
    }

    #[test]
    fn rejects_malformed_strings() {
        assert!(parse(&"ab".repeat(32)).is_err());
        assert!(parse("0xg").is_err());
        assert!(parse(&format!("0x{}", "zz".repeat(32))).is_err());
        assert!(AptosAddressFfi::new(vec![0u8; 31]).is_err());
    }
}
