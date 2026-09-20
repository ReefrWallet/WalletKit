//! `DerivationScheme`: the HD derivation scheme paired with a given curve.

use crate::common::CurveFfi;

#[derive(Debug, Clone, Copy, PartialEq, Eq, uniffi::Enum)]
pub enum DerivationScheme {
    Bip32,
    Slip0010,
}

impl DerivationScheme {
    pub fn for_curve(curve: CurveFfi) -> DerivationScheme {
        match curve {
            CurveFfi::Secp256k1 => DerivationScheme::Bip32,
            CurveFfi::Ed25519 => DerivationScheme::Slip0010,
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn derivation_scheme_differs_by_curve() {
        assert_eq!(DerivationScheme::for_curve(CurveFfi::Secp256k1), DerivationScheme::Bip32);
        assert_eq!(DerivationScheme::for_curve(CurveFfi::Ed25519), DerivationScheme::Slip0010);
        assert_ne!(DerivationScheme::Bip32, DerivationScheme::Slip0010);
    }
}
