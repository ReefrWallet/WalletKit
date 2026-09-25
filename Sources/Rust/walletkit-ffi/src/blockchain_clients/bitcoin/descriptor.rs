//! `BitcoinDescriptorFfi`: an account's stable identity — an output
//! descriptor of one of three shapes this crate produces and consumes
//! (never a general miniscript descriptor grammar, which is out of
//! scope — see the ADR):
//!
//! ```text
//! wpkh([1a2b3c4d/84'/0'/0']xpub6C.../<0;1>/*)   BIP-84 native SegWit
//! tr([1a2b3c4d/86'/0'/0']xpub6C.../<0;1>/*)     BIP-86 Taproot
//! addr(bc1q...)                                  watch-only single address
//! ```
//!
//! `wpkh`/`tr` descriptors derive external (chain `0`) and change (chain
//! `1`) addresses by non-hardened BIP-32 derivation from the account-level
//! xpub; `addr` wraps a single externally supplied address with no keys
//! behind it at all.

use std::str::FromStr;

use bitcoin::bip32::{ChildNumber, Xpub};
use bitcoin::hashes::Hash;
use bitcoin::key::UntweakedPublicKey;
use bitcoin::{Address, CompressedPublicKey};

use crate::blockchain_clients::bitcoin::address::BitcoinAddressFfi;
use crate::blockchain_clients::bitcoin::network::BitcoinNetworkFfi;
use crate::errors::WalletKitErrorFfi;

#[derive(Debug, Clone, Copy, PartialEq, Eq, uniffi::Enum)]
pub enum BitcoinScriptTypeFfi {
    P2wpkh,
    P2tr,
    /// A watch-only `addr(...)` descriptor — no derivable keys.
    SingleAddress,
}

#[derive(Debug, Clone, uniffi::Object)]
pub struct BitcoinDescriptorFfi {
    script_type: BitcoinScriptTypeFfi,
    network: BitcoinNetworkFfi,
    /// `None` only for `SingleAddress`.
    xpub: Option<Xpub>,
    master_fingerprint: [u8; 4],
    /// e.g. `[84', 0', 0']` — the account-level path the xpub above sits
    /// at, needed to record standards-compliant BIP-32 origin info
    /// (`bip32_derivation`/`tap_key_origins`) in built PSBTs.
    account_path: Vec<ChildNumber>,
    /// Only set for `SingleAddress`.
    single_address: Option<Address>,
}

fn invalid(reason: impl Into<String>) -> WalletKitErrorFfi {
    WalletKitErrorFfi::InvalidAddress { reason: reason.into() }
}

/// Computes the BIP-32 fingerprint for a compressed secp256k1 public
/// key — the first 4 bytes of `RIPEMD160(SHA256(pubkey))`. The Swift
/// side derives keys via its own from-scratch `ExtendedKeyFfi`, which
/// has no exported fingerprint accessor, so account creation
/// (`AccountService`) calls this directly to build a
/// `BitcoinDescriptorFfi` for a newly derived local account.
///
/// - Throws `.invalidAddress` if `public_key` isn't a valid 33-byte
///   compressed secp256k1 public key.
#[uniffi::export]
pub fn bitcoin_fingerprint(public_key: Vec<u8>) -> Result<Vec<u8>, WalletKitErrorFfi> {
    let key = bitcoin::secp256k1::PublicKey::from_slice(&public_key).map_err(|err| invalid(err.to_string()))?;
    let hash = bitcoin::hashes::hash160::Hash::hash(&key.serialize());
    Ok(hash.as_byte_array()[0..4].to_vec())
}


/// Parses a `/`-separated path of BIP-32 segments with no leading `m/`
/// (e.g. `84'/0'/0'` or `84'/0'/0'/0/5`) — shared with `psbt`, which needs
/// the same parsing for a PSBT input's full per-address path.
pub(super) fn parse_account_path(text: &str) -> Result<Vec<ChildNumber>, WalletKitErrorFfi> {
    text.split('/')
        .map(|segment| {
            if segment.is_empty() {
                return Err(invalid(format!("empty derivation segment in {text:?}")));
            }
            let hardened = segment.ends_with('\'');
            let digits = segment.trim_end_matches('\'');
            let index: u32 = digits.parse().map_err(|_| invalid(format!("bad derivation segment {segment:?}")))?;
            if hardened {
                ChildNumber::from_hardened_idx(index).map_err(|err| invalid(err.to_string()))
            } else {
                ChildNumber::from_normal_idx(index).map_err(|err| invalid(err.to_string()))
            }
        })
        .collect()
}

fn format_account_path(path: &[ChildNumber]) -> String {
    path.iter()
        .map(|child| match child {
            ChildNumber::Hardened { index } => format!("{index}'"),
            ChildNumber::Normal { index } => format!("{index}"),
        })
        .collect::<Vec<_>>()
        .join("/")
}

impl BitcoinDescriptorFfi {
    fn script_prefix(script_type: BitcoinScriptTypeFfi) -> Result<&'static str, WalletKitErrorFfi> {
        match script_type {
            BitcoinScriptTypeFfi::P2wpkh => Ok("wpkh"),
            BitcoinScriptTypeFfi::P2tr => Ok("tr"),
            BitcoinScriptTypeFfi::SingleAddress => {
                Err(invalid("SingleAddress descriptors have no xpub to format"))
            }
        }
    }

    fn derive_child_xpub(&self, chain: u32, index: u32) -> Result<Xpub, WalletKitErrorFfi> {
        let xpub = self.xpub.as_ref().ok_or_else(|| invalid("SingleAddress descriptor has no keys to derive"))?;
        let secp = bitcoin::secp256k1::Secp256k1::verification_only();
        let path = [
            ChildNumber::from_normal_idx(chain).map_err(|err| invalid(err.to_string()))?,
            ChildNumber::from_normal_idx(index).map_err(|err| invalid(err.to_string()))?,
        ];
        xpub.derive_pub(&secp, &path).map_err(|err| invalid(err.to_string()))
    }

    fn address_for(&self, public_key: bitcoin::secp256k1::PublicKey) -> Result<Address, WalletKitErrorFfi> {
        let network = bitcoin::Network::from(self.network);
        match self.script_type {
            BitcoinScriptTypeFfi::P2wpkh => Ok(Address::p2wpkh(&CompressedPublicKey(public_key), network)),
            BitcoinScriptTypeFfi::P2tr => {
                let secp = bitcoin::secp256k1::Secp256k1::verification_only();
                let (internal_key, _parity): (UntweakedPublicKey, _) = public_key.x_only_public_key();
                Ok(Address::p2tr(&secp, internal_key, None, network))
            }
            BitcoinScriptTypeFfi::SingleAddress => Err(invalid("SingleAddress descriptor derives no addresses")),
        }
    }
}

#[uniffi::export]
impl BitcoinDescriptorFfi {
    /// Builds a `wpkh(...)`/`tr(...)` descriptor from an account-level
    /// xpub and its BIP-32 origin (the master key's fingerprint and the
    /// hardened path the xpub sits at, e.g. `84'/0'/0'`).
    ///
    /// `network` is trusted as-is and not cross-checked against `xpub`'s
    /// own version bytes (xpub vs tpub): this crate's own `ExtendedKeyFfi`
    /// — the source of every xpub this constructor actually receives —
    /// always serializes with the mainnet version bytes regardless of
    /// which network the key is for (it has no network concept at all,
    /// being shared with Ethereum/Sui, which have no xpub/tpub
    /// distinction), so a real version-byte check would reject every
    /// non-mainnet xpub this codebase ever produces.
    ///
    /// - Throws `.invalidAddress` if `xpub` doesn't parse, `account_path`
    ///   isn't a well-formed `/`-separated path, `master_fingerprint`
    ///   isn't 4 bytes, or `script_type` is `.singleAddress` (which has
    ///   no xpub).
    #[uniffi::constructor]
    pub fn from_xpub(
        xpub: String,
        script_type: BitcoinScriptTypeFfi,
        network: BitcoinNetworkFfi,
        master_fingerprint: Vec<u8>,
        account_path: String,
    ) -> Result<BitcoinDescriptorFfi, WalletKitErrorFfi> {
        Self::script_prefix(script_type)?;

        let parsed_xpub = Xpub::from_str(&xpub).map_err(|err| invalid(err.to_string()))?;

        let fingerprint: [u8; 4] = master_fingerprint
            .as_slice()
            .try_into()
            .map_err(|_| invalid(format!("expected a 4-byte fingerprint, got {} bytes", master_fingerprint.len())))?;

        let path = parse_account_path(&account_path)?;

        Ok(BitcoinDescriptorFfi {
            script_type,
            network,
            xpub: Some(parsed_xpub),
            master_fingerprint: fingerprint,
            account_path: path,
            single_address: None,
        })
    }

    /// Builds a watch-only `addr(...)` descriptor wrapping a single
    /// address, with no derivable keys behind it.
    ///
    /// - Throws `.invalidAddress` if `address` doesn't parse for `network`.
    #[uniffi::constructor]
    pub fn from_address(address: String, network: BitcoinNetworkFfi) -> Result<BitcoinDescriptorFfi, WalletKitErrorFfi> {
        let parsed = BitcoinAddressFfi::from_string(address, network)?;
        Ok(BitcoinDescriptorFfi {
            script_type: BitcoinScriptTypeFfi::SingleAddress,
            network,
            xpub: None,
            master_fingerprint: [0; 4],
            account_path: Vec::new(),
            single_address: Some(parsed.inner().clone()),
        })
    }

    /// Parses one of this crate's own three descriptor text shapes (see
    /// module docs). `network` disambiguates testnet/signet/regtest, which
    /// share the same `tpub` version bytes and so can't be told apart from
    /// the descriptor text alone.
    ///
    /// - Throws `.invalidAddress` if `string` isn't one of the three
    ///   recognised shapes.
    #[uniffi::constructor]
    pub fn from_string(string: String, network: BitcoinNetworkFfi) -> Result<BitcoinDescriptorFfi, WalletKitErrorFfi> {
        if let Some(inner) = string.strip_prefix("addr(").and_then(|rest| rest.strip_suffix(')')) {
            return Self::from_address(inner.to_string(), network);
        }

        let (prefix, script_type) = if let Some(rest) = string.strip_prefix("wpkh(") {
            (rest, BitcoinScriptTypeFfi::P2wpkh)
        } else if let Some(rest) = string.strip_prefix("tr(") {
            (rest, BitcoinScriptTypeFfi::P2tr)
        } else {
            return Err(invalid(format!("unrecognised descriptor {string:?}")));
        };

        let body = prefix.strip_suffix(')').ok_or_else(|| invalid(format!("unterminated descriptor {string:?}")))?;

        let body = body.strip_prefix('[').ok_or_else(|| invalid(format!("missing key origin in {string:?}")))?;
        let (origin, rest) =
            body.split_once(']').ok_or_else(|| invalid(format!("unterminated key origin in {string:?}")))?;
        let (fingerprint_hex, account_path) =
            origin.split_once('/').ok_or_else(|| invalid(format!("malformed key origin {origin:?}")))?;

        let fingerprint = hex::decode(fingerprint_hex).map_err(|err| invalid(err.to_string()))?;

        let xpub_str = rest
            .strip_suffix("/<0;1>/*")
            .ok_or_else(|| invalid(format!("expected an `/<0;1>/*` multipath suffix in {string:?}")))?;

        Self::from_xpub(xpub_str.to_string(), script_type, network, fingerprint, account_path.to_string())
    }

    pub fn script_type(&self) -> BitcoinScriptTypeFfi {
        self.script_type
    }

    pub fn network(&self) -> BitcoinNetworkFfi {
        self.network
    }

    /// This descriptor's canonical text encoding — the same shape it was
    /// parsed/constructed from (see module docs).
    pub fn string(&self) -> Result<String, WalletKitErrorFfi> {
        match self.script_type {
            BitcoinScriptTypeFfi::SingleAddress => {
                let address = self.single_address.as_ref().ok_or_else(|| invalid("missing single address"))?;
                Ok(format!("addr({address})"))
            }
            _ => {
                let xpub = self.xpub.as_ref().ok_or_else(|| invalid("missing xpub"))?;
                let prefix = Self::script_prefix(self.script_type)?;
                Ok(format!(
                    "{prefix}([{}/{}]{xpub}/<0;1>/*)",
                    hex::encode(self.master_fingerprint),
                    format_account_path(&self.account_path)
                ))
            }
        }
    }

    /// Derives the address at `chain` (`0` = external/receive, `1` =
    /// change) and `index` — always the wrapped single address for a
    /// `SingleAddress` descriptor, regardless of `chain`/`index` (a
    /// watch-only address has no chain/index structure of its own, so
    /// every caller that only ever asks for `(0, 0)` gets back the one
    /// address it expects).
    pub fn derive_address(&self, chain: u32, index: u32) -> Result<std::sync::Arc<BitcoinAddressFfi>, WalletKitErrorFfi> {
        if self.script_type == BitcoinScriptTypeFfi::SingleAddress {
            let address = self.single_address.as_ref().ok_or_else(|| invalid("missing single address"))?;
            return Ok(std::sync::Arc::new(BitcoinAddressFfi::from_address(address.clone())));
        }

        let child = self.derive_child_xpub(chain, index)?;
        let address = self.address_for(child.public_key)?;
        Ok(std::sync::Arc::new(BitcoinAddressFfi::from_address(address)))
    }

    /// The 33-byte compressed secp256k1 public key at `chain`/`index` —
    /// what the transaction builder embeds in a PSBT input's
    /// `bip32_derivation`/`tap_key_origins` map, and what
    /// `BitcoinSignerFfi::sign_psbt` verifies each supplied private key
    /// against.
    ///
    /// - Throws `.keyNotFound` for `SingleAddress` — there is no key
    ///   behind a watch-only address.
    pub fn derive_public_key(&self, chain: u32, index: u32) -> Result<Vec<u8>, WalletKitErrorFfi> {
        if self.script_type == BitcoinScriptTypeFfi::SingleAddress {
            return Err(WalletKitErrorFfi::KeyNotFound);
        }
        let child = self.derive_child_xpub(chain, index)?;
        Ok(child.public_key.serialize().to_vec())
    }

    pub fn master_fingerprint(&self) -> Vec<u8> {
        self.master_fingerprint.to_vec()
    }

    /// The account-level path this descriptor's xpub sits at (e.g.
    /// `"84'/0'/0'"`, no leading `m/`) — empty for `SingleAddress`, which
    /// has no xpub. Callers append `/{chain}/{index}` to build a PSBT
    /// input's full per-address derivation path.
    pub fn account_path(&self) -> String {
        format_account_path(&self.account_path)
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::common::{CurveFfi, MnemonicWordCount, Wordlist};
    use crate::keys::MnemonicFfi;
    use bitcoin::hashes::Hash;

    /// Derives a real account-level xpub (and its master's fingerprint)
    /// from a freshly generated mnemonic — rather than a hand-typed xpub
    /// literal, which is exactly the kind of string a transcription
    /// mistake turns into a "base58 encoding error" instead of a useful
    /// test. The same pair is reused across every test below wanting "an
    /// account xpub", matching how the code under test treats the xpub
    /// as opaque to which script type ends up wrapping it.
    fn test_account() -> (String, Vec<u8>) {
        let seed = MnemonicFfi::generate(MnemonicWordCount::Words24, Wordlist::English).to_seed("".to_string());
        let master = seed.master_key(CurveFfi::Secp256k1);
        let secp = bitcoin::secp256k1::Secp256k1::new();
        let master_secret =
            bitcoin::secp256k1::SecretKey::from_slice(&master.private_key().unwrap().raw_bytes()).unwrap();
        let master_public = bitcoin::secp256k1::PublicKey::from_secret_key(&secp, &master_secret);
        let fingerprint = bitcoin::hashes::hash160::Hash::hash(&master_public.serialize()).as_byte_array()[0..4].to_vec();
        let account_key = master.derive(crate::common::DerivationPathFfi::parse("m/84'/0'/0'").unwrap()).unwrap();
        (account_key.serialized_public(), fingerprint)
    }

    #[test]
    fn bitcoin_fingerprint_matches_the_manually_computed_master_fingerprint() {
        let seed = MnemonicFfi::generate(MnemonicWordCount::Words24, Wordlist::English).to_seed("".to_string());
        let master = seed.master_key(CurveFfi::Secp256k1);
        let compressed = master.public_key().raw_bytes();
        assert_eq!(compressed.len(), 33);

        let secp = bitcoin::secp256k1::Secp256k1::new();
        let secret = bitcoin::secp256k1::SecretKey::from_slice(&master.private_key().unwrap().raw_bytes()).unwrap();
        let public = bitcoin::secp256k1::PublicKey::from_secret_key(&secp, &secret);
        let expected = bitcoin::hashes::hash160::Hash::hash(&public.serialize()).as_byte_array()[0..4].to_vec();

        assert_eq!(bitcoin_fingerprint(compressed).unwrap(), expected);
    }

    #[test]
    fn bitcoin_fingerprint_rejects_a_malformed_public_key() {
        assert!(matches!(bitcoin_fingerprint(vec![0u8; 10]), Err(WalletKitErrorFfi::InvalidAddress { .. })));
    }

    fn wpkh_descriptor() -> BitcoinDescriptorFfi {
        let (xpub, fingerprint) = test_account();
        BitcoinDescriptorFfi::from_xpub(
            xpub,
            BitcoinScriptTypeFfi::P2wpkh,
            BitcoinNetworkFfi::Mainnet,
            fingerprint,
            "84'/0'/0'".to_string(),
        )
        .unwrap()
    }

    #[test]
    fn string_round_trips_wpkh() {
        let (xpub, fingerprint) = test_account();
        let descriptor = BitcoinDescriptorFfi::from_xpub(
            xpub.clone(),
            BitcoinScriptTypeFfi::P2wpkh,
            BitcoinNetworkFfi::Mainnet,
            fingerprint.clone(),
            "84'/0'/0'".to_string(),
        )
        .unwrap();
        let text = descriptor.string().unwrap();
        assert_eq!(text, format!("wpkh([{}/84'/0'/0']{xpub}/<0;1>/*)", hex::encode(&fingerprint)));

        let reparsed = BitcoinDescriptorFfi::from_string(text, BitcoinNetworkFfi::Mainnet).unwrap();
        assert_eq!(reparsed.string().unwrap(), descriptor.string().unwrap());
    }

    #[test]
    fn string_round_trips_tr() {
        let (xpub, fingerprint) = test_account();
        let descriptor = BitcoinDescriptorFfi::from_xpub(
            xpub.clone(),
            BitcoinScriptTypeFfi::P2tr,
            BitcoinNetworkFfi::Mainnet,
            fingerprint.clone(),
            "86'/0'/0'".to_string(),
        )
        .unwrap();
        let text = descriptor.string().unwrap();
        assert_eq!(text, format!("tr([{}/86'/0'/0']{xpub}/<0;1>/*)", hex::encode(&fingerprint)));
        let reparsed = BitcoinDescriptorFfi::from_string(text, BitcoinNetworkFfi::Mainnet).unwrap();
        assert_eq!(reparsed.script_type(), BitcoinScriptTypeFfi::P2tr);
    }

    #[test]
    fn string_round_trips_single_address() {
        const ADDRESS: &str = "bc1qcr8te4kr609gcawutmrza0j4xv80jy8z306fyu";
        let descriptor = BitcoinDescriptorFfi::from_address(ADDRESS.to_string(), BitcoinNetworkFfi::Mainnet).unwrap();
        assert_eq!(descriptor.string().unwrap(), format!("addr({ADDRESS})"));

        let reparsed =
            BitcoinDescriptorFfi::from_string(format!("addr({ADDRESS})"), BitcoinNetworkFfi::Mainnet).unwrap();
        assert_eq!(reparsed.derive_address(0, 0).unwrap().string(), ADDRESS);
    }

    #[test]
    fn derive_address_produces_distinct_external_and_change_addresses() {
        let descriptor = wpkh_descriptor();
        let external = descriptor.derive_address(0, 0).unwrap();
        let change = descriptor.derive_address(1, 0).unwrap();
        assert_ne!(external.string(), change.string());
    }

    #[test]
    fn derive_address_is_deterministic() {
        let descriptor = wpkh_descriptor();
        let first = descriptor.derive_address(0, 5).unwrap();
        let second = descriptor.derive_address(0, 5).unwrap();
        assert_eq!(first.string(), second.string());
    }

    #[test]
    fn wpkh_and_tr_derive_different_addresses_for_the_same_xpub() {
        let (xpub, fingerprint) = test_account();
        let wpkh = BitcoinDescriptorFfi::from_xpub(
            xpub.clone(),
            BitcoinScriptTypeFfi::P2wpkh,
            BitcoinNetworkFfi::Mainnet,
            fingerprint.clone(),
            "84'/0'/0'".to_string(),
        )
        .unwrap();
        let tr = BitcoinDescriptorFfi::from_xpub(
            xpub,
            BitcoinScriptTypeFfi::P2tr,
            BitcoinNetworkFfi::Mainnet,
            fingerprint,
            "86'/0'/0'".to_string(),
        )
        .unwrap();
        assert_ne!(wpkh.derive_address(0, 0).unwrap().string(), tr.derive_address(0, 0).unwrap().string());
        assert!(tr.derive_address(0, 0).unwrap().string().starts_with("bc1p"));
        assert!(wpkh.derive_address(0, 0).unwrap().string().starts_with("bc1q"));
    }

    #[test]
    fn from_xpub_accepts_a_mainnet_style_xpub_for_a_test_network() {
        // `test_account()`'s xpub always carries mainnet version bytes
        // (see `ExtendedKeyFfi`'s module docs) — `from_xpub` must accept
        // it regardless of the requested network, trusting `network`
        // as-is rather than cross-checking it against the xpub's own
        // version bytes.
        let (xpub, fingerprint) = test_account();
        let descriptor = BitcoinDescriptorFfi::from_xpub(
            xpub,
            BitcoinScriptTypeFfi::P2wpkh,
            BitcoinNetworkFfi::Regtest,
            fingerprint,
            "84'/1'/0'".to_string(),
        )
        .unwrap();
        assert_eq!(descriptor.network(), BitcoinNetworkFfi::Regtest);
        assert!(descriptor.derive_address(0, 0).unwrap().string().starts_with("bcrt1q"));
    }

    #[test]
    fn from_xpub_rejects_a_bad_fingerprint_length() {
        let (xpub, _fingerprint) = test_account();
        assert!(matches!(
            BitcoinDescriptorFfi::from_xpub(
                xpub,
                BitcoinScriptTypeFfi::P2wpkh,
                BitcoinNetworkFfi::Mainnet,
                vec![0u8; 3],
                "84'/0'/0'".to_string(),
            ),
            Err(WalletKitErrorFfi::InvalidAddress { .. })
        ));
    }

    #[test]
    fn from_string_rejects_an_unrecognised_shape() {
        assert!(matches!(
            BitcoinDescriptorFfi::from_string("sh(wpkh(...))".to_string(), BitcoinNetworkFfi::Mainnet),
            Err(WalletKitErrorFfi::InvalidAddress { .. })
        ));
    }

    #[test]
    fn derive_public_key_matches_the_key_behind_the_derived_address() {
        let descriptor = wpkh_descriptor();
        let public_key = descriptor.derive_public_key(0, 0).unwrap();
        assert_eq!(public_key.len(), 33);

        let expected = Address::p2wpkh(
            &CompressedPublicKey(bitcoin::secp256k1::PublicKey::from_slice(&public_key).unwrap()),
            bitcoin::Network::Bitcoin,
        );
        assert_eq!(descriptor.derive_address(0, 0).unwrap().string(), expected.to_string());
    }

    #[test]
    fn single_address_descriptor_has_no_derivable_public_key() {
        let descriptor =
            BitcoinDescriptorFfi::from_address("bc1qcr8te4kr609gcawutmrza0j4xv80jy8z306fyu".to_string(), BitcoinNetworkFfi::Mainnet)
                .unwrap();
        assert!(matches!(descriptor.derive_public_key(0, 0), Err(WalletKitErrorFfi::KeyNotFound)));
    }
}
