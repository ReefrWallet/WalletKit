//! Unsigned PSBT assembly for a Bitcoin transfer. Building on the
//! `bitcoin` crate's own `Psbt`/`Transaction` types (rather than a
//! hand-rolled binary encoder) so the BIP-174 serialization itself is
//! exactly what that crate's own `Psbt::deserialize` — used by
//! `signer::BitcoinSignerFfi` and, eventually, Trezor's PSBT signing flow
//! — already parses correctly.

use std::str::FromStr;

use bitcoin::absolute::LockTime;
use bitcoin::bip32::{DerivationPath as BitcoinDerivationPath, Fingerprint};
use bitcoin::psbt::Psbt;
use bitcoin::secp256k1::{PublicKey, XOnlyPublicKey};
use bitcoin::transaction::Version;
use bitcoin::{Amount, OutPoint, ScriptBuf, Sequence, Transaction, TxIn, TxOut, Txid, Witness};

use crate::blockchain_clients::bitcoin::descriptor::parse_account_path;
use crate::errors::WalletKitErrorFfi;

/// One UTXO being spent. `public_key`/`master_fingerprint`/
/// `derivation_path` describe the owning address so the built PSBT
/// carries standards-compliant BIP-32 origin info (`bip32_derivation`/
/// `tap_key_origins`) for Trezor's benefit — `BitcoinSignerFfi::sign_psbt`
/// matches its supplied keys to inputs positionally instead and doesn't
/// need to read this back.
#[derive(Debug, Clone, uniffi::Record)]
pub struct BitcoinPsbtInputFfi {
    /// The funding transaction's id, display (RPC) hex order.
    pub txid: String,
    pub vout: u32,
    pub value_sats: u64,
    pub script_pubkey: Vec<u8>,
    /// 33-byte compressed secp256k1 public key owning this input — the
    /// x-only (last 32 bytes) is used directly for a taproot input.
    pub public_key: Vec<u8>,
    pub master_fingerprint: Vec<u8>,
    /// This input's full derivation path with no leading `m/`, e.g.
    /// `84'/0'/0'/0/5`.
    pub derivation_path: String,
    pub is_taproot: bool,
    /// The consensus-serialized funding transaction referenced by
    /// `txid`/`vout`, when known — populated as the PSBT's
    /// `non_witness_utxo`, which hardware signers (Trezor's `SignTx` flow
    /// in particular) require to independently verify the spent amount,
    /// even for a SegWit/Taproot input where `witness_utxo` alone would
    /// otherwise be sufficient. `None` for software-only signing (see
    /// `BitcoinPKeySigner`), which doesn't need it.
    pub non_witness_utxo: Option<Vec<u8>>,
}

#[derive(Debug, Clone, uniffi::Record)]
pub struct BitcoinPsbtOutputFfi {
    pub script_pubkey: Vec<u8>,
    pub value_sats: u64,
}

/// Which script type a to-be-spent input's key belongs to — only the two
/// this crate derives its own receive/change addresses as. Used solely by
/// `bitcoin_estimate_vsize`'s witness-size lookup.
#[derive(Debug, Clone, Copy, PartialEq, Eq, uniffi::Enum)]
pub enum BitcoinInputKindFfi {
    P2wpkh,
    P2tr,
}

/// One input's BIP-32 origin, read back from a built PSBT — what
/// `BitcoinPKeySigner` needs to derive the matching private key for each
/// input before calling `BitcoinSignerFfi::sign_psbt`, since that method
/// matches its supplied keys to inputs positionally rather than reading
/// this back itself.
#[derive(Debug, Clone, uniffi::Record)]
pub struct BitcoinPsbtInputDerivationFfi {
    pub master_fingerprint: Vec<u8>,
    /// The input's full derivation path with no leading `m/`, e.g.
    /// `"84'/0'/0'/0/5"`.
    pub derivation_path: String,
    pub is_taproot: bool,
}

/// Reads back each input's BIP-32 origin from `psbt`'s
/// `bip32_derivation` (P2WPKH) or `tap_key_origins` (P2TR) map, in input
/// order.
///
/// - Throws `.invalidAddress` if `psbt` doesn't deserialize, or an input
///   has neither map populated (i.e. wasn't built by
///   `bitcoin_build_unsigned_psbt`).
#[uniffi::export]
pub fn bitcoin_psbt_input_derivations(psbt: Vec<u8>) -> Result<Vec<BitcoinPsbtInputDerivationFfi>, WalletKitErrorFfi> {
    let psbt = Psbt::deserialize(&psbt).map_err(|err| invalid(err.to_string()))?;

    psbt.inputs
        .iter()
        .map(|input| {
            if let Some((_, (_leaf_hashes, (fingerprint, path)))) = input.tap_key_origins.iter().next() {
                Ok(BitcoinPsbtInputDerivationFfi {
                    master_fingerprint: fingerprint.to_bytes().to_vec(),
                    derivation_path: path.to_string(),
                    is_taproot: true,
                })
            } else if let Some((_, (fingerprint, path))) = input.bip32_derivation.iter().next() {
                Ok(BitcoinPsbtInputDerivationFfi {
                    master_fingerprint: fingerprint.to_bytes().to_vec(),
                    derivation_path: path.to_string(),
                    is_taproot: false,
                })
            } else {
                Err(invalid("input has no BIP-32 derivation info"))
            }
        })
        .collect()
}

fn invalid(reason: impl Into<String>) -> WalletKitErrorFfi {
    WalletKitErrorFfi::InvalidAddress { reason: reason.into() }
}

fn fixed_bytes<const N: usize>(bytes: &[u8], what: &str) -> Result<[u8; N], WalletKitErrorFfi> {
    bytes.try_into().map_err(|_| invalid(format!("expected a {N}-byte {what}, got {} bytes", bytes.len())))
}

/// Builds unsigned PSBT bytes for a transfer spending `inputs` into
/// `outputs`. Every input's `witness_utxo` and BIP-32 origin info are
/// populated so the PSBT is ready for `BitcoinSignerFfi::sign_psbt` with no
/// further enrichment; an input's `non_witness_utxo` is populated too when
/// supplied, which a Trezor's own PSBT signing flow requires (`witness_utxo`
/// alone isn't enough for it to independently verify the spent amount).
///
/// - Throws `.invalidAddress` if `inputs` is empty, a `txid` doesn't parse,
///   a `public_key`/`master_fingerprint` isn't the expected byte length, a
///   `derivation_path` isn't a well-formed `/`-separated path, or a
///   supplied `non_witness_utxo` doesn't deserialize or doesn't hash to
///   the input's own `txid`.
#[uniffi::export]
pub fn bitcoin_build_unsigned_psbt(
    inputs: Vec<BitcoinPsbtInputFfi>,
    outputs: Vec<BitcoinPsbtOutputFfi>,
    locktime: u32,
) -> Result<Vec<u8>, WalletKitErrorFfi> {
    if inputs.is_empty() {
        return Err(invalid("a transaction needs at least one input"));
    }

    let tx_inputs = inputs
        .iter()
        .map(|input| {
            let txid = Txid::from_str(&input.txid).map_err(|err| invalid(err.to_string()))?;
            Ok(TxIn {
                previous_output: OutPoint { txid, vout: input.vout },
                script_sig: ScriptBuf::new(),
                // RBF intentionally left disabled — out of scope (see the ADR).
                sequence: Sequence::ENABLE_LOCKTIME_NO_RBF,
                witness: Witness::default(),
            })
        })
        .collect::<Result<Vec<_>, WalletKitErrorFfi>>()?;

    let tx_outputs: Vec<TxOut> = outputs
        .iter()
        .map(|output| TxOut {
            value: Amount::from_sat(output.value_sats),
            script_pubkey: ScriptBuf::from_bytes(output.script_pubkey.clone()),
        })
        .collect();

    let unsigned_tx = Transaction {
        version: Version::TWO,
        lock_time: LockTime::from_consensus(locktime),
        input: tx_inputs,
        output: tx_outputs,
    };

    let mut psbt = Psbt::from_unsigned_tx(unsigned_tx).map_err(|err| invalid(err.to_string()))?;

    for (i, input) in inputs.iter().enumerate() {
        psbt.inputs[i].witness_utxo = Some(TxOut {
            value: Amount::from_sat(input.value_sats),
            script_pubkey: ScriptBuf::from_bytes(input.script_pubkey.clone()),
        });

        if let Some(raw) = &input.non_witness_utxo {
            let previous_tx: Transaction =
                bitcoin::consensus::deserialize(raw).map_err(|err| invalid(err.to_string()))?;
            if previous_tx.compute_txid() != psbt.unsigned_tx.input[i].previous_output.txid {
                return Err(invalid("non_witness_utxo does not match the input's txid"));
            }
            psbt.inputs[i].non_witness_utxo = Some(previous_tx);
        }

        let fingerprint = fixed_bytes::<4>(&input.master_fingerprint, "fingerprint")?;
        let path = parse_account_path(&input.derivation_path)?;
        let key_source = (Fingerprint::from(fingerprint), BitcoinDerivationPath::from(path));

        if input.is_taproot {
            let x_only_bytes = fixed_bytes::<32>(
                input.public_key.get(input.public_key.len().saturating_sub(32)..).unwrap_or_default(),
                "x-only public key",
            )?;
            let x_only = XOnlyPublicKey::from_slice(&x_only_bytes).map_err(|err| invalid(err.to_string()))?;
            psbt.inputs[i].tap_internal_key = Some(x_only);
            psbt.inputs[i].tap_key_origins.insert(x_only, (Vec::new(), key_source));
        } else {
            let pk = PublicKey::from_slice(&input.public_key).map_err(|err| invalid(err.to_string()))?;
            psbt.inputs[i].bip32_derivation.insert(pk, key_source);
        }
    }

    Ok(psbt.serialize())
}

/// The transaction fee already implied by a PSBT built by
/// `bitcoin_build_unsigned_psbt` — `sum(input witness_utxo values) -
/// sum(output values)`. Lets a caller show the real fee a just-built
/// transfer will pay without waiting for it to be signed or broadcast.
///
/// - Throws `.invalidAddress` if `psbt` doesn't deserialize, an input is
///   missing its `witness_utxo` (i.e. wasn't built by
///   `bitcoin_build_unsigned_psbt`), or the outputs sum to more than the
///   inputs.
#[uniffi::export]
pub fn bitcoin_psbt_fee(psbt: Vec<u8>) -> Result<u64, WalletKitErrorFfi> {
    let psbt = Psbt::deserialize(&psbt).map_err(|err| invalid(err.to_string()))?;
    let fee = psbt.fee().map_err(|err| invalid(err.to_string()))?;
    Ok(fee.to_sat())
}

/// Estimates a transaction's virtual size in vbytes from its input/output
/// shapes — approximate (used only for a fee estimate, never for
/// consensus), using widely cited per-item vsize contributions: a P2WPKH
/// input contributes ~68 vB, a P2TR key-path input ~57.5 vB (rounded up to
/// 58); the ~10.5 vB base overhead (version, locktime, segwit marker/flag,
/// input/output count varints) is rounded up to 11. Each output's
/// contribution is computed directly from its real scriptPubKey length
/// (8-byte value + a 1-byte length varint, accurate for every standard
/// script, all well under the 253-byte varint boundary) rather than a
/// lookup table, since a recipient output can be any script type.
#[uniffi::export]
pub fn bitcoin_estimate_vsize(input_kinds: Vec<BitcoinInputKindFfi>, output_script_pubkeys: Vec<Vec<u8>>) -> u64 {
    const BASE_OVERHEAD_VBYTES: u64 = 11;
    const P2WPKH_INPUT_VBYTES: u64 = 68;
    const P2TR_INPUT_VBYTES: u64 = 58;

    let input_total: u64 = input_kinds
        .iter()
        .map(|kind| match kind {
            BitcoinInputKindFfi::P2wpkh => P2WPKH_INPUT_VBYTES,
            BitcoinInputKindFfi::P2tr => P2TR_INPUT_VBYTES,
        })
        .sum();
    let output_total: u64 = output_script_pubkeys.iter().map(|script| 8 + 1 + script.len() as u64).sum();

    BASE_OVERHEAD_VBYTES + input_total + output_total
}

#[cfg(test)]
mod tests {
    use super::*;

    /// secp256k1's generator point `G`, compressed encoding — a
    /// universally known constant, used here only to give these tests a
    /// syntactically valid public key (an arbitrary 33 bytes starting with
    /// `0x02`/`0x03` is not a point on the curve and `PublicKey::from_slice`
    /// correctly rejects it).
    const GENERATOR_POINT_COMPRESSED: &str = "0279be667ef9dcbbac55a06295ce870b07029bfcdb2dce28d959f2815b16f81798";

    fn wpkh_input(txid: &str) -> BitcoinPsbtInputFfi {
        BitcoinPsbtInputFfi {
            txid: txid.to_string(),
            vout: 0,
            value_sats: 100_000,
            script_pubkey: vec![0x00, 0x14].into_iter().chain(std::iter::repeat_n(0xab, 20)).collect(),
            public_key: hex::decode(GENERATOR_POINT_COMPRESSED).unwrap(),
            master_fingerprint: vec![0x1a, 0x2b, 0x3c, 0x4d],
            derivation_path: "84'/0'/0'/0/5".to_string(),
            is_taproot: false,
            non_witness_utxo: None,
        }
    }

    fn output(value_sats: u64) -> BitcoinPsbtOutputFfi {
        BitcoinPsbtOutputFfi {
            script_pubkey: vec![0x00, 0x14].into_iter().chain(std::iter::repeat_n(0xcd, 20)).collect(),
            value_sats,
        }
    }

    /// A syntactically valid (64 hex characters), otherwise arbitrary txid
    /// — built rather than hand-typed so its length can't be mistyped.
    fn test_txid() -> String {
        "ab".repeat(32)
    }

    #[test]
    fn build_unsigned_psbt_round_trips_through_deserialize() {
        let bytes =
            bitcoin_build_unsigned_psbt(vec![wpkh_input(&test_txid())], vec![output(90_000)], 0).unwrap();
        let psbt = Psbt::deserialize(&bytes).unwrap();
        assert_eq!(psbt.inputs.len(), 1);
        assert_eq!(psbt.unsigned_tx.output.len(), 1);
        assert_eq!(psbt.unsigned_tx.output[0].value, Amount::from_sat(90_000));
    }

    #[test]
    fn psbt_input_derivations_round_trips_a_wpkh_inputs_origin() {
        let bytes = bitcoin_build_unsigned_psbt(vec![wpkh_input(&test_txid())], vec![output(90_000)], 0).unwrap();
        let derivations = bitcoin_psbt_input_derivations(bytes).unwrap();
        assert_eq!(derivations.len(), 1);
        assert_eq!(derivations[0].master_fingerprint, vec![0x1a, 0x2b, 0x3c, 0x4d]);
        assert_eq!(derivations[0].derivation_path, "84'/0'/0'/0/5");
        assert!(!derivations[0].is_taproot);
    }

    #[test]
    fn psbt_input_derivations_round_trips_a_taproot_inputs_origin() {
        let mut input = wpkh_input(&test_txid());
        input.is_taproot = true;
        input.derivation_path = "86'/0'/0'/0/5".to_string();

        let bytes = bitcoin_build_unsigned_psbt(vec![input], vec![output(90_000)], 0).unwrap();
        let derivations = bitcoin_psbt_input_derivations(bytes).unwrap();
        assert_eq!(derivations.len(), 1);
        assert_eq!(derivations[0].derivation_path, "86'/0'/0'/0/5");
        assert!(derivations[0].is_taproot);
    }

    #[test]
    fn psbt_input_derivations_rejects_malformed_psbt_bytes() {
        assert!(matches!(
            bitcoin_psbt_input_derivations(vec![0xff, 0x00]),
            Err(WalletKitErrorFfi::InvalidAddress { .. })
        ));
    }

    #[test]
    fn build_unsigned_psbt_records_witness_utxo() {
        let bytes =
            bitcoin_build_unsigned_psbt(vec![wpkh_input(&test_txid())], vec![output(90_000)], 0).unwrap();
        let psbt = Psbt::deserialize(&bytes).unwrap();
        assert_eq!(psbt.inputs[0].witness_utxo.as_ref().unwrap().value, Amount::from_sat(100_000));
    }

    /// A self-consistent funding transaction: its own computed txid, used
    /// as the spending input's `txid` below, so `non_witness_utxo`'s
    /// consistency check passes without needing real chain data.
    fn funding_transaction(value_sats: u64) -> Transaction {
        Transaction {
            version: Version::TWO,
            lock_time: LockTime::ZERO,
            input: vec![],
            output: vec![TxOut { value: Amount::from_sat(value_sats), script_pubkey: ScriptBuf::new() }],
        }
    }

    #[test]
    fn build_unsigned_psbt_records_a_provided_non_witness_utxo() {
        let funding = funding_transaction(100_000);
        let mut input = wpkh_input(&funding.compute_txid().to_string());
        input.non_witness_utxo = Some(bitcoin::consensus::serialize(&funding));

        let bytes = bitcoin_build_unsigned_psbt(vec![input], vec![output(90_000)], 0).unwrap();
        let psbt = Psbt::deserialize(&bytes).unwrap();
        assert_eq!(psbt.inputs[0].non_witness_utxo.as_ref().unwrap().compute_txid(), funding.compute_txid());
    }

    #[test]
    fn build_unsigned_psbt_rejects_a_non_witness_utxo_that_does_not_match_the_txid() {
        let funding = funding_transaction(100_000);
        // `wpkh_input`'s own txid, not `funding`'s — deliberately inconsistent.
        let mut input = wpkh_input(&test_txid());
        input.non_witness_utxo = Some(bitcoin::consensus::serialize(&funding));

        assert!(matches!(
            bitcoin_build_unsigned_psbt(vec![input], vec![output(90_000)], 0),
            Err(WalletKitErrorFfi::InvalidAddress { .. })
        ));
    }

    #[test]
    fn psbt_fee_is_inputs_minus_outputs() {
        let bytes =
            bitcoin_build_unsigned_psbt(vec![wpkh_input(&test_txid())], vec![output(90_000)], 0).unwrap();
        // wpkh_input() funds 100_000 sats; output() spends 90_000.
        assert_eq!(bitcoin_psbt_fee(bytes).unwrap(), 10_000);
    }

    #[test]
    fn psbt_fee_rejects_malformed_psbt_bytes() {
        assert!(matches!(bitcoin_psbt_fee(vec![0xff, 0x00]), Err(WalletKitErrorFfi::InvalidAddress { .. })));
    }

    #[test]
    fn build_unsigned_psbt_records_bip32_derivation_for_a_wpkh_input() {
        let bytes =
            bitcoin_build_unsigned_psbt(vec![wpkh_input(&test_txid())], vec![output(90_000)], 0).unwrap();
        let psbt = Psbt::deserialize(&bytes).unwrap();
        assert_eq!(psbt.inputs[0].bip32_derivation.len(), 1);
        let (_, path) = psbt.inputs[0].bip32_derivation.values().next().unwrap();
        assert_eq!(path.to_string(), "84'/0'/0'/0/5");
    }

    #[test]
    fn build_unsigned_psbt_records_tap_key_origins_for_a_taproot_input() {
        let mut input = wpkh_input(&test_txid());
        input.is_taproot = true;
        input.derivation_path = "86'/0'/0'/0/5".to_string();

        let bytes = bitcoin_build_unsigned_psbt(vec![input], vec![output(90_000)], 0).unwrap();
        let psbt = Psbt::deserialize(&bytes).unwrap();
        assert!(psbt.inputs[0].tap_internal_key.is_some());
        assert_eq!(psbt.inputs[0].tap_key_origins.len(), 1);
    }

    #[test]
    fn build_unsigned_psbt_rejects_no_inputs() {
        assert!(matches!(
            bitcoin_build_unsigned_psbt(vec![], vec![output(90_000)], 0),
            Err(WalletKitErrorFfi::InvalidAddress { .. })
        ));
    }

    #[test]
    fn build_unsigned_psbt_rejects_an_unparseable_txid() {
        assert!(matches!(
            bitcoin_build_unsigned_psbt(vec![wpkh_input("not-a-txid")], vec![output(90_000)], 0),
            Err(WalletKitErrorFfi::InvalidAddress { .. })
        ));
    }

    #[test]
    fn estimate_vsize_grows_with_more_inputs_and_outputs() {
        let one_input_one_output =
            bitcoin_estimate_vsize(vec![BitcoinInputKindFfi::P2wpkh], vec![output(1).script_pubkey]);
        let two_inputs_two_outputs = bitcoin_estimate_vsize(
            vec![BitcoinInputKindFfi::P2wpkh, BitcoinInputKindFfi::P2wpkh],
            vec![output(1).script_pubkey, output(1).script_pubkey],
        );
        assert!(two_inputs_two_outputs > one_input_one_output);
    }

    #[test]
    fn estimate_vsize_taproot_input_is_smaller_than_wpkh() {
        let wpkh = bitcoin_estimate_vsize(vec![BitcoinInputKindFfi::P2wpkh], vec![]);
        let tr = bitcoin_estimate_vsize(vec![BitcoinInputKindFfi::P2tr], vec![]);
        assert!(tr < wpkh);
    }
}
