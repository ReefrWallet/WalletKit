//
//  BitcoinBackend.swift
//  WalletKit
//

import Foundation
import WalletKitRust

extension Data {
    /// Plain (non-`0x`-prefixed) lowercase hex — what Bitcoin's wire
    /// protocols expect (Electrum's `blockchain.transaction.broadcast`,
    /// Esplora's `POST /tx`), unlike Ethereum's `0x`-prefixed convention
    /// (``hexEncoded``, in `HexCoding.swift`). Mixing the two up here
    /// isn't just cosmetic — bitcoind's raw-transaction decoder reads the
    /// leading `"0x"` as if it were transaction bytes and misparses the
    /// whole stream, rather than cleanly rejecting it.
    var bitcoinHexEncoded: String {
        map { String(format: "%02x", $0) }.joined()
    }
}

/// One unspent output at an address this account controls.
public struct BitcoinUTXO: Sendable, Equatable {
    public let txid: String
    public let vout: UInt32
    public let valueSats: UInt64
    public let scriptPubkey: Data
    /// Which chain (`0` external, `1` change) and index derived the
    /// address this UTXO belongs to — carried through to
    /// ``BitcoinTransactionBuilder`` so it can populate a PSBT input's
    /// BIP-32 origin without re-deriving it.
    public let chain: UInt32
    public let index: UInt32
    public let confirmed: Bool

    public init(
        txid: String,
        vout: UInt32,
        valueSats: UInt64,
        scriptPubkey: Data,
        chain: UInt32,
        index: UInt32,
        confirmed: Bool
    ) {
        self.txid = txid
        self.vout = vout
        self.valueSats = valueSats
        self.scriptPubkey = scriptPubkey
        self.chain = chain
        self.index = index
        self.confirmed = confirmed
    }
}

/// One historical transaction touching an address, as a backend reports
/// it — the minimal shape needed to union/dedupe/sort activity across
/// every discovered address before hydrating the survivors with
/// ``BitcoinBackend/transaction(txid:)``.
public struct BitcoinBackendHistoryEntry: Sendable, Equatable, Hashable {
    public let txid: String
    /// `nil` for an unconfirmed (mempool) transaction.
    public let height: UInt64?

    public init(txid: String, height: UInt64?) {
        self.txid = txid
        self.height = height
    }
}

/// One transaction's full detail, as a backend reports it.
public struct BitcoinBackendTransaction: Sendable {
    public let txid: String
    public let height: UInt64?
    public let blockTime: Date?
    /// `(scriptPubkey, valueSats)` for every input this transaction
    /// spends — needed to compute the net effect against the account's
    /// own address set (an input's script has no value of its own; the
    /// spent output's value must be looked up from the backend).
    public let inputs: [(scriptPubkey: Data, valueSats: UInt64)]
    public let outputs: [(scriptPubkey: Data, valueSats: UInt64)]

    public init(
        txid: String,
        height: UInt64?,
        blockTime: Date?,
        inputs: [(scriptPubkey: Data, valueSats: UInt64)],
        outputs: [(scriptPubkey: Data, valueSats: UInt64)]
    ) {
        self.txid = txid
        self.height = height
        self.blockTime = blockTime
        self.inputs = inputs
        self.outputs = outputs
    }
}

/// The transport-level seam below ``BitcoinClient`` — everything
/// chain-level (gap-limit resolution, history unioning, fee-estimate
/// normalization) is written once against this protocol in
/// ``BitcoinClient``; ``ElectrumBackend`` and ``EsploraBackend`` are its
/// two conformers, differing only in how they reach the same data.
protocol BitcoinBackend: Sendable {
    /// Confirmed and unconfirmed balance, in sats, for one address.
    func balance(of address: BitcoinAddressFfi) async throws -> (confirmed: UInt64, unconfirmed: Int64)

    /// Every historical transaction touching `address`. Electrum returns
    /// this in one call; ``EsploraBackend`` pages internally and returns
    /// the full result, since callers need the complete per-address
    /// history to union across every discovered address.
    func history(of address: BitcoinAddressFfi) async throws -> [BitcoinBackendHistoryEntry]

    /// Every unspent output currently sitting at `address`.
    func utxos(of address: BitcoinAddressFfi, chain: UInt32, index: UInt32) async throws -> [BitcoinUTXO]

    /// Full detail for `txid`.
    func transaction(txid: String) async throws -> BitcoinBackendTransaction

    /// The consensus-serialized raw bytes of `txid`'s transaction — the
    /// PSBT input's `non_witness_utxo` a Trezor's `SignTx` flow requires
    /// to independently verify a spent amount (see
    /// ``BitcoinTransactionBuilder``).
    func rawTransaction(txid: String) async throws -> Data

    /// The current network fee rate, in sat/vB, targeting confirmation
    /// within `blocks` blocks.
    func estimateFeeRate(blocks: Int) async throws -> Double

    /// Broadcasts `rawTransaction` (a finalized, consensus-serialized
    /// transaction) and returns its txid.
    func broadcast(rawTransaction: Data) async throws -> String

    /// The current chain tip height — what
    /// ``BitcoinClient/transactionHistory(_:request:)`` reports as
    /// ``BlockchainTransactionPage/head``, the same role
    /// `eth_blockNumber`/`GetServiceInfo.checkpointHeight` play for
    /// Ethereum/Sui: it's what `TransactionSyncService` needs to
    /// establish `currentHead` and start forward polling once the
    /// descending backfill has run at least once.
    func currentHeight() async throws -> UInt64

    /// Streams newly observed chain heads. Resolves immediately with
    /// ``WalletKitError/unsupportedFeature`` for a backend with no push
    /// transport (``EsploraBackend``).
    func headsStream() -> AsyncThrowingStream<BlockchainTransactionHead, any Swift.Error>
}
