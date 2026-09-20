//! `BitcoinAddressFfi`: a validated Bitcoin address, backed by the
//! `bitcoin` crate's own `Address` type rather than a hand-rolled
//! base58check/bech32/bech32m decoder — those encodings (and their
//! checksums) are exactly what `bitcoin::Address`'s `FromStr` already
//! implements correctly for P2PKH/P2SH (base58check), P2WPKH/P2WSH
//! (bech32), and P2TR (bech32m).

use std::str::FromStr;

use bitcoin::address::{Address, NetworkUnchecked};
use bitcoin::ScriptBuf;

use crate::blockchain_clients::bitcoin::network::BitcoinNetworkFfi;
use crate::errors::WalletKitErrorFfi;

#[derive(Debug, Clone, PartialEq, Eq, uniffi::Object)]
pub struct BitcoinAddressFfi {
    inner: Address,
}

impl BitcoinAddressFfi {
    pub(crate) fn from_address(inner: Address) -> BitcoinAddressFfi {
        BitcoinAddressFfi { inner }
    }

    pub(crate) fn inner(&self) -> &Address {
        &self.inner
    }
}

#[uniffi::export]
impl BitcoinAddressFfi {
    /// Parses `string` as a Bitcoin address for `network` — P2PKH/P2SH
    /// (base58check), P2WPKH/P2WSH (bech32), or P2TR (bech32m).
    ///
    /// - Throws `.invalidAddress` if `string` doesn't decode as any known
    ///   address encoding, or decodes but is tagged for a different
    ///   network than `network`.
    #[uniffi::constructor]
    pub fn from_string(string: String, network: BitcoinNetworkFfi) -> Result<BitcoinAddressFfi, WalletKitErrorFfi> {
        let invalid = |reason: String| WalletKitErrorFfi::InvalidAddress { reason };
        let unchecked = Address::<NetworkUnchecked>::from_str(&string).map_err(|err| invalid(err.to_string()))?;
        let checked = unchecked.require_network(network.into()).map_err(|err| invalid(err.to_string()))?;
        Ok(BitcoinAddressFfi { inner: checked })
    }

    /// Wraps a raw scriptPubKey as a `BitcoinAddressFfi` for `network` —
    /// used when an Electrum/Esplora response gives back a script rather
    /// than an address string. Supports P2PKH, P2SH, and any witness
    /// program (P2WPKH, P2WSH, P2TR).
    ///
    /// - Throws `.invalidAddress` if `script_pubkey` isn't a recognised
    ///   standard script.
    #[uniffi::constructor]
    pub fn from_script_pubkey(
        script_pubkey: Vec<u8>,
        network: BitcoinNetworkFfi,
    ) -> Result<BitcoinAddressFfi, WalletKitErrorFfi> {
        let script = ScriptBuf::from_bytes(script_pubkey);
        let address = Address::from_script(&script, bitcoin::Network::from(network))
            .map_err(|err| WalletKitErrorFfi::InvalidAddress { reason: err.to_string() })?;
        Ok(BitcoinAddressFfi { inner: address })
    }

    /// This address's canonical string encoding (base58check, bech32, or
    /// bech32m, matching how it was parsed/constructed).
    pub fn string(&self) -> String {
        self.inner.to_string()
    }

    /// This address's scriptPubKey — the bytes an output paying it encodes,
    /// and (for Electrum) the input to the scripthash subscription key.
    pub fn script_pubkey(&self) -> Vec<u8> {
        self.inner.script_pubkey().to_bytes()
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    // Well-known published vectors: BIP-84 test vector 0 (mainnet P2WPKH)
    // and a widely cited BIP-86 P2TR mainnet address, plus a legacy P2PKH
    // address, so all three encodings this type must round-trip are
    // exercised independently of anything this crate derives itself.
    const P2WPKH_MAINNET: &str = "bc1qcr8te4kr609gcawutmrza0j4xv80jy8z306fyu";
    const P2TR_MAINNET: &str = "bc1p5cyxnuxmeuwuvkwfem96lqzszd02n6xdcjrs20cac6yqjjwudpxqkedrcr";
    const P2PKH_MAINNET: &str = "1BvBMSEYstWetqTFn5Au4m4GFg7xJaNVN2";

    #[test]
    fn from_string_round_trips_p2wpkh() {
        let address = BitcoinAddressFfi::from_string(P2WPKH_MAINNET.to_string(), BitcoinNetworkFfi::Mainnet).unwrap();
        assert_eq!(address.string(), P2WPKH_MAINNET);
    }

    #[test]
    fn from_string_round_trips_p2tr() {
        let address = BitcoinAddressFfi::from_string(P2TR_MAINNET.to_string(), BitcoinNetworkFfi::Mainnet).unwrap();
        assert_eq!(address.string(), P2TR_MAINNET);
    }

    #[test]
    fn from_string_round_trips_p2pkh() {
        let address = BitcoinAddressFfi::from_string(P2PKH_MAINNET.to_string(), BitcoinNetworkFfi::Mainnet).unwrap();
        assert_eq!(address.string(), P2PKH_MAINNET);
    }

    #[test]
    fn from_string_rejects_a_network_mismatch() {
        assert!(matches!(
            BitcoinAddressFfi::from_string(P2WPKH_MAINNET.to_string(), BitcoinNetworkFfi::Testnet),
            Err(WalletKitErrorFfi::InvalidAddress { .. })
        ));
    }

    #[test]
    fn from_string_rejects_garbage() {
        assert!(matches!(
            BitcoinAddressFfi::from_string("not-an-address".to_string(), BitcoinNetworkFfi::Mainnet),
            Err(WalletKitErrorFfi::InvalidAddress { .. })
        ));
    }

    #[test]
    fn script_pubkey_round_trips_through_from_script_pubkey() {
        let address = BitcoinAddressFfi::from_string(P2WPKH_MAINNET.to_string(), BitcoinNetworkFfi::Mainnet).unwrap();
        let script = address.script_pubkey();
        let rebuilt = BitcoinAddressFfi::from_script_pubkey(script, BitcoinNetworkFfi::Mainnet).unwrap();
        assert_eq!(rebuilt.string(), P2WPKH_MAINNET);
    }

    #[test]
    fn from_script_pubkey_rejects_a_non_standard_script() {
        // `OP_RETURN <empty>` — not a recognised standard script.
        assert!(matches!(
            BitcoinAddressFfi::from_script_pubkey(vec![0x6a], BitcoinNetworkFfi::Mainnet),
            Err(WalletKitErrorFfi::InvalidAddress { .. })
        ));
    }
}
