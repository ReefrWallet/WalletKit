//! `BigIntFfi`: an arbitrary-precision, sign-and-magnitude integer that
//! crosses the UniFFI boundary as big-endian bytes plus a sign flag —
//! the same shape attaswift/BigInt's `BigInt(sign:magnitude:)` uses on
//! the Swift side (see `Sources/Core/BigInt.swift`), so `BigInt`/`BigUInt`
//! round-trip through this type without any bit-twiddling on either side.
//!
//! `magnitude_be_bytes` is always the *minimal* big-endian encoding — no
//! leading zero bytes, and zero itself is an empty vec — matching
//! `BigUInt.serialize()`'s convention exactly, so both sides produce
//! byte-identical output for the same value.
//!
//! Also convertible to/from `u64`/`u128` and the fixed-width integer
//! aliases `alloy_primitives` defines (shared by this crate's
//! Ethereum/EVM code and reused for Sui's same-width Move integers):
//! `U128`/`U160`/`U256`/`U512` and signed `I128`/`I160`/`I256`/`I512`.
//! Chain-specific Rust code works in its native integer type and only
//! reaches for `BigIntFfi` at the FFI boundary.

use alloy_primitives::aliases::{I128, I160, I256, I512, U128, U160, U256, U512};
use alloy_primitives::Sign;

use crate::errors::WalletKitErrorFfi;

#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct BigIntFfi {
    pub magnitude_be_bytes: Vec<u8>,
    pub negative: bool,
}

impl BigIntFfi {
    /// Trims `magnitude_be_bytes` to its minimal form and normalizes the
    /// sign of zero to non-negative, so equal values always compare equal
    /// and always serialize identically regardless of how they were built.
    fn new(magnitude_be_bytes: Vec<u8>, negative: bool) -> BigIntFfi {
        let first_nonzero = magnitude_be_bytes.iter().position(|&byte| byte != 0);
        let trimmed = match first_nonzero {
            Some(index) => magnitude_be_bytes[index..].to_vec(),
            None => Vec::new(),
        };
        let negative = negative && !trimmed.is_empty();
        BigIntFfi { magnitude_be_bytes: trimmed, negative }
    }

    fn overflow_error(bits: usize) -> WalletKitErrorFfi {
        WalletKitErrorFfi::InvalidBigInt { reason: format!("magnitude does not fit in {bits} bits") }
    }

    fn negative_error(type_name: &str) -> WalletKitErrorFfi {
        WalletKitErrorFfi::InvalidBigInt {
            reason: format!("cannot represent a negative value as unsigned {type_name}"),
        }
    }
}

impl From<u64> for BigIntFfi {
    fn from(value: u64) -> Self {
        BigIntFfi::new(value.to_be_bytes().to_vec(), false)
    }
}

impl TryFrom<&BigIntFfi> for u64 {
    type Error = WalletKitErrorFfi;

    fn try_from(value: &BigIntFfi) -> Result<Self, Self::Error> {
        if value.negative {
            return Err(BigIntFfi::negative_error("u64"));
        }
        if value.magnitude_be_bytes.len() > 8 {
            return Err(BigIntFfi::overflow_error(64));
        }
        let mut buffer = [0u8; 8];
        let offset = 8 - value.magnitude_be_bytes.len();
        buffer[offset..].copy_from_slice(&value.magnitude_be_bytes);
        Ok(u64::from_be_bytes(buffer))
    }
}

impl From<u128> for BigIntFfi {
    fn from(value: u128) -> Self {
        BigIntFfi::new(value.to_be_bytes().to_vec(), false)
    }
}

impl TryFrom<&BigIntFfi> for u128 {
    type Error = WalletKitErrorFfi;

    fn try_from(value: &BigIntFfi) -> Result<Self, Self::Error> {
        if value.negative {
            return Err(BigIntFfi::negative_error("u128"));
        }
        if value.magnitude_be_bytes.len() > 16 {
            return Err(BigIntFfi::overflow_error(128));
        }
        let mut buffer = [0u8; 16];
        let offset = 16 - value.magnitude_be_bytes.len();
        buffer[offset..].copy_from_slice(&value.magnitude_be_bytes);
        Ok(u128::from_be_bytes(buffer))
    }
}

/// Implements `From<$unsigned> for BigIntFfi` and
/// `TryFrom<&BigIntFfi> for $unsigned` for each `alloy_primitives`
/// unsigned `Uint<BITS, LIMBS>` alias listed.
macro_rules! impl_unsigned_conversions {
    ($($unsigned:ty),+ $(,)?) => {
        $(
            impl From<$unsigned> for BigIntFfi {
                fn from(value: $unsigned) -> Self {
                    BigIntFfi::new(value.to_be_bytes_vec(), false)
                }
            }

            impl TryFrom<&BigIntFfi> for $unsigned {
                type Error = WalletKitErrorFfi;

                fn try_from(value: &BigIntFfi) -> Result<Self, Self::Error> {
                    if value.negative {
                        return Err(BigIntFfi::negative_error(stringify!($unsigned)));
                    }
                    <$unsigned>::try_from_be_slice(&value.magnitude_be_bytes)
                        .ok_or_else(|| BigIntFfi::overflow_error(<$unsigned>::BITS))
                }
            }
        )+
    };
}

/// Implements `From<$signed> for BigIntFfi` and
/// `TryFrom<&BigIntFfi> for $signed` for each `alloy_primitives` signed
/// `Signed<BITS, LIMBS>` alias listed, paired with its same-width
/// unsigned magnitude type.
macro_rules! impl_signed_conversions {
    ($(($signed:ty, $unsigned:ty)),+ $(,)?) => {
        $(
            impl From<$signed> for BigIntFfi {
                fn from(value: $signed) -> Self {
                    let (sign, magnitude) = value.into_sign_and_abs();
                    BigIntFfi::new(magnitude.to_be_bytes_vec(), sign.is_negative())
                }
            }

            impl TryFrom<&BigIntFfi> for $signed {
                type Error = WalletKitErrorFfi;

                fn try_from(value: &BigIntFfi) -> Result<Self, Self::Error> {
                    let magnitude = <$unsigned>::try_from_be_slice(&value.magnitude_be_bytes)
                        .ok_or_else(|| BigIntFfi::overflow_error(<$unsigned>::BITS))?;
                    let sign = if value.negative { Sign::Negative } else { Sign::Positive };
                    <$signed>::checked_from_sign_and_abs(sign, magnitude)
                        .ok_or_else(|| BigIntFfi::overflow_error(<$unsigned>::BITS))
                }
            }
        )+
    };
}

impl_unsigned_conversions!(U128, U160, U256, U512);
impl_signed_conversions!((I128, U128), (I160, U160), (I256, U256), (I512, U512));

/// Returns `value` unchanged. A pure round trip across the UniFFI
/// boundary, so Swift tests can confirm arbitrary-width `BigIntFfi`
/// values (beyond what fits in a native FFI scalar) survive the trip
/// intact.
#[uniffi::export]
pub fn big_int_echo(value: BigIntFfi) -> BigIntFfi {
    value
}

/// Constructs a `BigIntFfi` from a `u64`, computed Rust-side — lets a
/// Swift test confirm the numeric (not just byte-copying) conversion
/// logic is correct across the FFI boundary.
#[uniffi::export]
pub fn big_int_from_u64(value: u64) -> BigIntFfi {
    value.into()
}

/// Reads a `BigIntFfi` back out as a `u64`.
///
/// Throws `.invalidBigInt` if `value` is negative or too large to fit.
#[uniffi::export]
pub fn big_int_to_u64(value: BigIntFfi) -> Result<u64, WalletKitErrorFfi> {
    u64::try_from(&value)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn zero_normalizes_to_an_empty_non_negative_magnitude() {
        let zero = BigIntFfi::new(vec![0, 0, 0], true);
        assert_eq!(zero, BigIntFfi { magnitude_be_bytes: vec![], negative: false });
    }

    #[test]
    fn new_trims_leading_zero_bytes() {
        let value = BigIntFfi::new(vec![0, 0, 1, 2], false);
        assert_eq!(value.magnitude_be_bytes, vec![1, 2]);
    }

    #[test]
    fn u64_round_trips_including_max() {
        for value in [0u64, 1, 42, u64::MAX] {
            let ffi = BigIntFfi::from(value);
            assert_eq!(u64::try_from(&ffi).unwrap(), value);
        }
    }

    #[test]
    fn u64_rejects_negative_and_oversized_values() {
        let negative = BigIntFfi { magnitude_be_bytes: vec![1], negative: true };
        assert!(matches!(u64::try_from(&negative), Err(WalletKitErrorFfi::InvalidBigInt { .. })));

        let oversized = BigIntFfi { magnitude_be_bytes: vec![1; 9], negative: false };
        assert!(matches!(u64::try_from(&oversized), Err(WalletKitErrorFfi::InvalidBigInt { .. })));
    }

    #[test]
    fn u128_round_trips_including_max() {
        for value in [0u128, 1, u64::MAX as u128 + 1, u128::MAX] {
            let ffi = BigIntFfi::from(value);
            assert_eq!(u128::try_from(&ffi).unwrap(), value);
        }
    }

    #[test]
    fn unsigned_alloy_aliases_round_trip_including_max() {
        assert_eq!(U128::try_from(&BigIntFfi::from(U128::MAX)).unwrap(), U128::MAX);
        assert_eq!(U160::try_from(&BigIntFfi::from(U160::MAX)).unwrap(), U160::MAX);
        assert_eq!(U256::try_from(&BigIntFfi::from(U256::MAX)).unwrap(), U256::MAX);
        assert_eq!(U512::try_from(&BigIntFfi::from(U512::MAX)).unwrap(), U512::MAX);
        assert_eq!(U256::try_from(&BigIntFfi::from(U256::ZERO)).unwrap(), U256::ZERO);
    }

    #[test]
    fn unsigned_alloy_aliases_reject_negative_and_oversized_values() {
        let negative = BigIntFfi { magnitude_be_bytes: vec![1], negative: true };
        assert!(matches!(U256::try_from(&negative), Err(WalletKitErrorFfi::InvalidBigInt { .. })));

        let oversized = BigIntFfi::from(U512::MAX);
        assert!(matches!(U256::try_from(&oversized), Err(WalletKitErrorFfi::InvalidBigInt { .. })));
    }

    #[test]
    fn signed_alloy_aliases_round_trip_positive_negative_and_zero() {
        for value in [I256::ZERO, I256::ONE, -I256::ONE, I256::MAX, I256::MIN] {
            assert_eq!(I256::try_from(&BigIntFfi::from(value)).unwrap(), value);
        }
        assert_eq!(I128::try_from(&BigIntFfi::from(I128::MIN)).unwrap(), I128::MIN);
        assert_eq!(I160::try_from(&BigIntFfi::from(I160::MIN)).unwrap(), I160::MIN);
        assert_eq!(I512::try_from(&BigIntFfi::from(I512::MIN)).unwrap(), I512::MIN);
    }

    #[test]
    fn signed_alloy_aliases_reject_oversized_magnitudes() {
        let oversized = BigIntFfi::from(U256::MAX);
        assert!(matches!(I128::try_from(&oversized), Err(WalletKitErrorFfi::InvalidBigInt { .. })));
    }

    #[test]
    fn negative_bigintffi_carries_a_negative_alloy_signed_value() {
        let negative_one = BigIntFfi { magnitude_be_bytes: vec![1], negative: true };
        assert_eq!(I256::try_from(&negative_one).unwrap(), -I256::ONE);
    }

    #[test]
    fn big_int_echo_returns_its_input_unchanged() {
        let value = BigIntFfi::from(U512::MAX);
        assert_eq!(big_int_echo(value.clone()), value);
    }

    #[test]
    fn big_int_from_u64_and_to_u64_round_trip() {
        let ffi = big_int_from_u64(u64::MAX);
        assert_eq!(big_int_to_u64(ffi).unwrap(), u64::MAX);
    }

    #[test]
    fn big_int_to_u64_rejects_a_negative_value() {
        let negative = BigIntFfi { magnitude_be_bytes: vec![1], negative: true };
        assert!(matches!(big_int_to_u64(negative), Err(WalletKitErrorFfi::InvalidBigInt { .. })));
    }
}
