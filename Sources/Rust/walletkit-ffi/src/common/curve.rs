//! `CurveFfi`: the elliptic curve a key/derivation scheme is based on.

#[derive(Debug, Clone, Copy, PartialEq, Eq, uniffi::Enum)]
pub enum CurveFfi {
    Secp256k1,
    Ed25519,
}

impl CurveFfi {
    pub const ALL: [CurveFfi; 2] = [CurveFfi::Secp256k1, CurveFfi::Ed25519];
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn curve_all_cases_are_distinct() {
        assert_eq!(CurveFfi::ALL.len(), 2);
        assert_ne!(CurveFfi::Secp256k1, CurveFfi::Ed25519);
    }
}
