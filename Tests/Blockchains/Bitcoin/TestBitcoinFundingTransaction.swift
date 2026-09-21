// Shared test helper for BitcoinTransactionBuilderTests/BitcoinTrezorSignerTests.

import CryptoKit
import Foundation

/// A minimal, self-consistent funding transaction (one dummy input, one
/// output paying `scriptPubkey`) — its own computed txid, in standard
/// reversed-byte-order hex, so a PSBT input built from it satisfies both
/// `bitcoin_build_unsigned_psbt`'s `non_witness_utxo` consistency check
/// and a real Trezor's own cross-check that `witness_utxo`'s declared
/// scriptPubkey/value actually matches what `non_witness_utxo` records at
/// the spent output — without needing real chain data. `scriptPubkey`
/// must be under 253 bytes (true for the P2WPKH/P2TR scripts this crate
/// derives) so its length fits a single-byte varint.
///
/// Deliberately not zero-input: a legacy transaction with zero inputs is
/// indistinguishable from a BIP144 SegWit marker byte, which
/// `bitcoin::consensus::deserialize` rejects as malformed.
///
/// `nonce` only exists to make two funding transactions with the same
/// `scriptPubkey`/`valueSats` hash differently.
func makeFundingTransaction(scriptPubkey: Data, valueSats: UInt64, nonce: UInt8) -> (txid: String, raw: Data) {
    var raw = Data([0x02, 0x00, 0x00, 0x00]) // version 2, little-endian.
    raw.append(0x01) // input count varint: one (dummy) input.
    raw.append(Data(repeating: nonce, count: 32)) // dummy previous txid, varied by nonce.
    raw.append(contentsOf: [0xFF, 0xFF, 0xFF, 0xFF]) // dummy previous vout.
    raw.append(0x00) // scriptSig length varint: empty.
    raw.append(contentsOf: [0xFF, 0xFF, 0xFF, 0xFF]) // sequence: arbitrary.
    raw.append(0x01) // output count varint: one output.
    withUnsafeBytes(of: valueSats.littleEndian) { raw.append(contentsOf: $0) }
    raw.append(UInt8(scriptPubkey.count)) // scriptPubkey length varint.
    raw.append(scriptPubkey)
    raw.append(contentsOf: [0x00, 0x00, 0x00, 0x00]) // locktime.

    let hash = SHA256.hash(data: Data(SHA256.hash(data: raw)))
    let txid = Data(hash).reversed().map { String(format: "%02x", $0) }.joined()
    return (txid, raw)
}
