//! `DerivationPath`: a BIP32/SLIP-10-style derivation path (e.g.
//! `m/44'/60'/0'/0/0`).

use crate::common::Segment;
use crate::errors::WalletKitErrorFfi;

#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct DerivationPath {
    pub segments: Vec<Segment>,
}

impl DerivationPath {
    pub fn new(segments: Vec<Segment>) -> DerivationPath {
        DerivationPath { segments }
    }

    /// Parses a `m/44'/60'/0'/0/0`-style string. Fails with
    /// `InvalidDerivationPath` on anything malformed.
    pub fn parse(path: &str) -> Result<DerivationPath, WalletKitErrorFfi> {
        let invalid = || WalletKitErrorFfi::InvalidDerivationPath {
            path: path.to_string(),
        };

        let mut parts = path.split('/');
        if parts.next() != Some("m") {
            return Err(invalid());
        }

        let segments = parts
            .map(|part| {
                if part.is_empty() {
                    return Err(invalid());
                }
                let hardened = part.ends_with(['\'', 'h', 'H']);
                let digits = part.trim_end_matches(['\'', 'h', 'H']);
                digits
                    .parse::<u32>()
                    .map(|index| Segment { index, hardened })
                    .map_err(|_| invalid())
            })
            .collect::<Result<Vec<_>, _>>()?;

        if segments.is_empty() {
            return Err(invalid());
        }
        Ok(DerivationPath { segments })
    }

    pub fn string(&self) -> String {
        let mut result = String::from("m");
        for segment in &self.segments {
            result.push('/');
            result.push_str(&segment.index.to_string());
            if segment.hardened {
                result.push('\'');
            }
        }
        result
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn parses_standard_bip44_string() {
        let path = DerivationPath::parse("m/44'/60'/0'/0/0").unwrap();
        assert_eq!(
            path.segments.iter().map(|s| s.index).collect::<Vec<_>>(),
            vec![44, 60, 0, 0, 0]
        );
        assert_eq!(
            path.segments.iter().map(|s| s.hardened).collect::<Vec<_>>(),
            vec![true, true, true, false, false]
        );
    }

    #[test]
    fn string_round_trips_through_parsing() {
        let original = "m/44'/60'/0'/0/0";
        let path = DerivationPath::parse(original).unwrap();
        assert_eq!(path.string(), original);
    }

    #[test]
    fn invalid_string_throws_invalid_derivation_path() {
        let err = DerivationPath::parse("not-a-path").unwrap_err();
        assert!(matches!(err, WalletKitErrorFfi::InvalidDerivationPath { .. }));
    }
}
