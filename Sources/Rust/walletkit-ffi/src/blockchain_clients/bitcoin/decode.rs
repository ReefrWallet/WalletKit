//! Decodes an arbitrary raw (consensus-serialized) Bitcoin transaction
//! into its inputs/outputs — the piece `ElectrumClient` needs to hydrate
//! transaction history from `blockchain.transaction.get`'s *non-verbose*
//! response (plain raw hex, universally supported) rather than its
//! verbose one, which Blockstream's `electrs` never implemented
//! (`// FIXME: implement verbose support` in its own source — confirmed
//! against a real regtest `electrs` instance, not just documentation).

use bitcoin::Transaction;

use crate::errors::WalletKitErrorFfi;

/// One input's outpoint — absent entirely for a coinbase input, which
/// has no real previous output to attribute value/scriptPubkey to.
#[derive(Debug, Clone, uniffi::Record)]
pub struct BitcoinDecodedInputFfi {
    pub txid: String,
    pub vout: u32,
}

#[derive(Debug, Clone, uniffi::Record)]
pub struct BitcoinDecodedOutputFfi {
    pub script_pubkey: Vec<u8>,
    pub value_sats: u64,
}

#[derive(Debug, Clone, uniffi::Record)]
pub struct BitcoinDecodedTransactionFfi {
    pub txid: String,
    /// Every non-coinbase input's outpoint, in transaction order —
    /// coinbase inputs are dropped, since they have no previous output
    /// a caller could look up.
    pub inputs: Vec<BitcoinDecodedInputFfi>,
    pub outputs: Vec<BitcoinDecodedOutputFfi>,
}

/// Decodes `raw` — the consensus-serialized bytes `blockchain.transaction.get`
/// returns in non-verbose mode (or an Esplora `/tx/:txid/hex` response) —
/// into its txid, inputs, and outputs.
///
/// - Throws `.invalidAddress` if `raw` doesn't deserialize as a
///   well-formed Bitcoin transaction.
#[uniffi::export]
pub fn bitcoin_decode_transaction(raw: Vec<u8>) -> Result<BitcoinDecodedTransactionFfi, WalletKitErrorFfi> {
    let tx: Transaction = bitcoin::consensus::deserialize(&raw)
        .map_err(|err| WalletKitErrorFfi::InvalidAddress { reason: err.to_string() })?;

    let inputs = tx
        .input
        .iter()
        .filter(|input| !input.previous_output.is_null())
        .map(|input| BitcoinDecodedInputFfi {
            txid: input.previous_output.txid.to_string(),
            vout: input.previous_output.vout,
        })
        .collect();

    let outputs = tx
        .output
        .iter()
        .map(|output| BitcoinDecodedOutputFfi {
            script_pubkey: output.script_pubkey.to_bytes(),
            value_sats: output.value.to_sat(),
        })
        .collect();

    Ok(BitcoinDecodedTransactionFfi { txid: tx.compute_txid().to_string(), inputs, outputs })
}

#[cfg(test)]
mod tests {
    use super::*;
    use bitcoin::absolute::LockTime;
    use bitcoin::transaction::Version;
    use bitcoin::{Amount, OutPoint, ScriptBuf, Sequence, TxIn, TxOut, Txid, Witness};
    use std::str::FromStr;

    fn sample_transaction() -> Transaction {
        let previous_txid = Txid::from_str(&"ab".repeat(32)).unwrap();
        Transaction {
            version: Version::TWO,
            lock_time: LockTime::ZERO,
            input: vec![TxIn {
                previous_output: OutPoint { txid: previous_txid, vout: 1 },
                script_sig: ScriptBuf::new(),
                sequence: Sequence::ENABLE_LOCKTIME_NO_RBF,
                witness: Witness::default(),
            }],
            output: vec![TxOut { value: Amount::from_sat(50_000), script_pubkey: ScriptBuf::from_bytes(vec![0x51]) }],
        }
    }

    #[test]
    fn decode_transaction_recovers_the_real_txid_and_every_field() {
        let tx = sample_transaction();
        let raw = bitcoin::consensus::serialize(&tx);

        let decoded = bitcoin_decode_transaction(raw).unwrap();
        assert_eq!(decoded.txid, tx.compute_txid().to_string());
        assert_eq!(decoded.inputs.len(), 1);
        assert_eq!(decoded.inputs[0].txid, "ab".repeat(32));
        assert_eq!(decoded.inputs[0].vout, 1);
        assert_eq!(decoded.outputs.len(), 1);
        assert_eq!(decoded.outputs[0].value_sats, 50_000);
        assert_eq!(decoded.outputs[0].script_pubkey, vec![0x51]);
    }

    #[test]
    fn decode_transaction_drops_a_coinbase_input() {
        let mut tx = sample_transaction();
        tx.input[0].previous_output = OutPoint::null();

        let decoded = bitcoin_decode_transaction(bitcoin::consensus::serialize(&tx)).unwrap();
        assert!(decoded.inputs.is_empty());
    }

    #[test]
    fn decode_transaction_rejects_malformed_bytes() {
        assert!(matches!(
            bitcoin_decode_transaction(vec![0xff, 0x00]),
            Err(WalletKitErrorFfi::InvalidAddress { .. })
        ));
    }
}
