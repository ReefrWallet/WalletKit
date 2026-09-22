//! `SolanaAddressFfi`: a validated Solana address (32 raw bytes) —
//! plain (non-checksummed) Base58 of an ed25519 public key, or of a
//! program-derived address that is intentionally off the ed25519 curve.
//! See `Walletkit/Docs/Design Specification/Clients/Solana/SolanaAddress.swift`.

use ed25519_dalek::VerifyingKey;

use crate::errors::WalletKitErrorFfi;

#[derive(Debug, Clone, Copy, PartialEq, Eq, uniffi::Object)]
pub struct SolanaAddressFfi {
    raw_bytes: [u8; 32],
}

impl SolanaAddressFfi {
    pub(crate) fn from_raw(raw_bytes: [u8; 32]) -> SolanaAddressFfi {
        SolanaAddressFfi { raw_bytes }
    }
}

#[uniffi::export]
impl SolanaAddressFfi {
    /// Wraps `raw_bytes` as a `SolanaAddressFfi`. Throws `.invalidAddress`
    /// if `raw_bytes.len() != 32`.
    #[uniffi::constructor]
    pub fn new(raw_bytes: Vec<u8>) -> Result<SolanaAddressFfi, WalletKitErrorFfi> {
        let array: [u8; 32] = raw_bytes.as_slice().try_into().map_err(|_| WalletKitErrorFfi::InvalidAddress {
            reason: format!("expected 32 raw bytes, got {}", raw_bytes.len()),
        })?;
        Ok(SolanaAddressFfi { raw_bytes: array })
    }

    /// Parses `string` as a Solana address: plain (non-checksummed)
    /// Base58 decoding to exactly 32 bytes. Throws `.invalidAddress` for
    /// non-Base58 characters or a decoded length other than 32.
    #[uniffi::constructor]
    pub fn from_string(string: String) -> Result<SolanaAddressFfi, WalletKitErrorFfi> {
        let invalid = |reason: String| WalletKitErrorFfi::InvalidAddress { reason };
        let bytes = bs58::decode(&string).into_vec().map_err(|err| invalid(err.to_string()))?;
        let array: [u8; 32] = bytes
            .as_slice()
            .try_into()
            .map_err(|_| invalid(format!("expected 32 bytes, got {}", bytes.len())))?;
        Ok(SolanaAddressFfi { raw_bytes: array })
    }

    pub fn raw_bytes(&self) -> Vec<u8> {
        self.raw_bytes.to_vec()
    }

    /// Plain (non-checksummed) Base58 encoding — Solana's standard address
    /// format.
    pub fn string(&self) -> String {
        bs58::encode(self.raw_bytes).into_string()
    }

    /// Whether these 32 bytes decompress to a valid ed25519 curve point.
    /// A wallet address must be on-curve (it's a real public key); a
    /// program-derived address must be off-curve (see
    /// `solana_find_program_address`), which is what lets a single
    /// 32-byte address space distinguish the two without a type tag.
    pub fn is_on_curve(&self) -> bool {
        VerifyingKey::from_bytes(&self.raw_bytes).is_ok()
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn new_rejects_the_wrong_byte_count() {
        assert!(matches!(SolanaAddressFfi::new(vec![0u8; 31]), Err(WalletKitErrorFfi::InvalidAddress { .. })));
    }

    #[test]
    fn string_round_trips_through_from_string() {
        let raw: Vec<u8> = (0u8..32).collect();
        let address = SolanaAddressFfi::new(raw.clone()).unwrap();
        let parsed = SolanaAddressFfi::from_string(address.string()).unwrap();
        assert_eq!(parsed.raw_bytes(), raw);
    }

    #[test]
    fn from_string_rejects_non_base58_characters() {
        // '0', 'O', 'I', 'l' are excluded from the Base58 alphabet.
        assert!(matches!(
            SolanaAddressFfi::from_string("0OIl".repeat(10)),
            Err(WalletKitErrorFfi::InvalidAddress { .. })
        ));
    }

    #[test]
    fn from_string_rejects_the_wrong_decoded_length() {
        assert!(matches!(
            SolanaAddressFfi::from_string("abc".to_string()),
            Err(WalletKitErrorFfi::InvalidAddress { .. })
        ));
    }

    #[test]
    fn well_known_system_program_address_round_trips() {
        // The System Program's address is the all-zero 32 bytes, whose
        // canonical Base58 string is "11111111111111111111111111111111".
        let address = SolanaAddressFfi::new(vec![0u8; 32]).unwrap();
        assert_eq!(address.string(), "11111111111111111111111111111111");
        assert_eq!(SolanaAddressFfi::from_string(address.string()).unwrap(), address);
    }

    #[test]
    fn is_on_curve_is_true_for_a_real_ed25519_public_key() {
        use ed25519_dalek::SigningKey;
        let signing_key = SigningKey::from_bytes(&[7u8; 32]);
        let address = SolanaAddressFfi::new(signing_key.verifying_key().to_bytes().to_vec()).unwrap();
        assert!(address.is_on_curve());
    }

    #[test]
    fn is_on_curve_is_false_for_bytes_that_are_not_a_curve_point() {
        // A real PDA — off-curve by construction (see
        // `pda::tests::associated_token_address_matches_an_independently_
        // computed_vector`), unlike an arbitrary bit pattern such as
        // 0xFF-repeated, which can decompress differently across ed25519
        // implementations when its non-canonical y-coordinate happens to
        // still yield a square root.
        let pda: Vec<u8> = vec![
            98, 121, 233, 122, 65, 162, 114, 59, 135, 125, 43, 225, 44, 3, 106, 129, 212, 216, 169, 248, 114, 193,
            79, 22, 28, 199, 198, 170, 62, 20, 21, 131,
        ];
        let address = SolanaAddressFfi::new(pda).unwrap();
        assert!(!address.is_on_curve());
    }
}
