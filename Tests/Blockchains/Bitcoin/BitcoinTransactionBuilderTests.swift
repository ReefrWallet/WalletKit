// Exercises the Swift-side Bitcoin wiring end to end — descriptor
// derivation, coin selection, PSBT building, software signing, and
// broadcast — against a `MockBitcoinBackend` rather than a real
// Electrum/Esplora server (that's Phase 6's job, once local `bitcoind` +
// `electrs` test infrastructure exists). The PSBT build→sign→finalize→
// extract round trip itself is already exhaustively tested on the Rust
// side (WalletKit/Sources/Rust/walletkit-ffi/src/blockchain_clients/
// bitcoin/signer.rs) with real vector-derived keys and a real BIP-341
// taproot tweak; this suite instead checks that the Swift layer glues
// the resolver, coin selector, builder, and signer together correctly.

import BigInt
import Foundation
import Testing
@testable import WalletKit
import WalletKitRust

private actor MockBitcoinBackend: BitcoinBackend {
    private var utxosByScript: [Data: [BitcoinUTXO]] = [:]
    private var rawTransactionsByTxid: [String: Data] = [:]
    private(set) var broadcastedTransactions: [Data] = []
    var feeRateSatPerVByte: Double = 5

    func seed(scriptPubkey: Data, utxos: [BitcoinUTXO]) {
        utxosByScript[scriptPubkey] = utxos
    }

    func seedRawTransaction(txid: String, raw: Data) {
        rawTransactionsByTxid[txid] = raw
    }

    func balance(of address: BitcoinAddressFfi) async throws -> (confirmed: UInt64, unconfirmed: Int64) {
        let total = (utxosByScript[address.scriptPubkey()] ?? []).reduce(UInt64(0)) { $0 + $1.valueSats }
        return (confirmed: total, unconfirmed: 0)
    }

    func history(of address: BitcoinAddressFfi) async throws -> [BitcoinBackendHistoryEntry] {
        guard let utxos = utxosByScript[address.scriptPubkey()], !utxos.isEmpty else { return [] }
        return [BitcoinBackendHistoryEntry(txid: String(repeating: "a", count: 64), height: 100)]
    }

    func utxos(of address: BitcoinAddressFfi, chain: UInt32, index: UInt32) async throws -> [BitcoinUTXO] {
        utxosByScript[address.scriptPubkey()] ?? []
    }

    func transaction(txid: String) async throws -> BitcoinBackendTransaction {
        throw BlockchainClientError.invalidResponse(reason: "not exercised by this test")
    }

    func rawTransaction(txid: String) async throws -> Data {
        guard let raw = rawTransactionsByTxid[txid] else {
            throw BlockchainClientError.invalidResponse(reason: "no raw transaction seeded for \(txid)")
        }
        return raw
    }

    func estimateFeeRate(blocks: Int) async throws -> Double {
        feeRateSatPerVByte
    }

    func broadcast(rawTransaction: Data) async throws -> String {
        broadcastedTransactions.append(rawTransaction)
        return String(repeating: "b", count: 64)
    }

    nonisolated func headsStream() -> AsyncThrowingStream<BlockchainTransactionHead, any Swift.Error> {
        AsyncThrowingStream { continuation in
            continuation.finish(throwing: WalletKitError.unsupportedFeature)
        }
    }
}

/// Derives a fresh, real (never hand-typed) account descriptor from a
/// newly generated mnemonic — every field a `BitcoinDescriptor` needs
/// (xpub, master fingerprint, account path) is computed the same way
/// `AccountService` will in the app layer, so a mistake here would be a
/// mistake there too.
private func makeAccount(
    network: BitcoinNetwork,
    scriptType: BitcoinScriptType
) throws -> (descriptor: BitcoinDescriptor, seed: Seed, accountDerivationPath: DerivationPath) {
    let seed = Mnemonic.generate().toSeed()
    let masterKey = try seed.masterKey(curve: .secp256k1)
    let masterFingerprint = try BitcoinDescriptor.fingerprint(of: masterKey.publicKey)

    let accountDerivationPath = try DerivationPath.bitcoinAccount(
        network: network,
        scriptType: scriptType,
        accountIndex: 0
    )
    let accountKey = try masterKey.derive(accountDerivationPath)
    let accountPathText = String(accountDerivationPath.string.dropFirst(2)) // drop the leading "m/".

    let descriptor = try BitcoinDescriptor(
        xpub: accountKey.serializedPublic(),
        scriptType: scriptType,
        network: network,
        masterFingerprint: masterFingerprint,
        accountPath: accountPathText
    )
    return (descriptor, seed, accountDerivationPath)
}

struct BitcoinTransactionBuilderTests {
    @Test func buildSignFinalizeAndBroadcastASimpleWpkhTransfer() async throws {
        let (sender, senderSeed, senderPath) = try makeAccount(network: .regtest, scriptType: .p2wpkh)
        let (recipient, _, _) = try makeAccount(network: .regtest, scriptType: .p2wpkh)

        let fundingAddress = try sender.deriveAddress(chain: 0, index: 0)
        let funding = makeFundingTransaction(scriptPubkey: fundingAddress.scriptPubkey(), valueSats: 100_000, nonce: 0xC0)
        let backend = MockBitcoinBackend()
        await backend.seed(scriptPubkey: fundingAddress.scriptPubkey(), utxos: [
            BitcoinUTXO(
                txid: funding.txid,
                vout: 0,
                valueSats: 100_000,
                scriptPubkey: fundingAddress.scriptPubkey(),
                chain: 0,
                index: 0,
                confirmed: true
            ),
        ])
        await backend.seedRawTransaction(txid: funding.txid, raw: funding.raw)

        let client = BitcoinClient(backend: backend)
        let builder = BitcoinTransactionBuilder(client: client)

        let psbt = try await builder.buildTransfer(
            sender: sender, recipient: recipient, amount: BigUInt(50_000), token: nil, options: []
        )
        #expect(!psbt.isEmpty)

        let signer = try BitcoinPKeySigner(descriptor: sender, seed: senderSeed, derivationPath: senderPath)
        let finalized = try await signer.sign(transaction: psbt)

        // A minimal sanity check on shape, independent of the Rust side's
        // own exhaustive extract/deserialize tests: version 2, little-endian.
        #expect(finalized.count > 60)
        #expect(finalized.prefix(4) == Data([0x02, 0x00, 0x00, 0x00]))

        let txid = try await client.broadcast(transaction: psbt, signature: finalized)
        #expect(txid.count == 64)

        let broadcasted = await backend.broadcastedTransactions
        #expect(broadcasted == [finalized])
    }

    @Test func buildSignFinalizeAndBroadcastASimpleTaprootTransfer() async throws {
        let (sender, senderSeed, senderPath) = try makeAccount(network: .regtest, scriptType: .p2tr)
        let (recipient, _, _) = try makeAccount(network: .regtest, scriptType: .p2tr)

        let fundingAddress = try sender.deriveAddress(chain: 0, index: 0)
        let funding = makeFundingTransaction(scriptPubkey: fundingAddress.scriptPubkey(), valueSats: 100_000, nonce: 0xD0)
        let backend = MockBitcoinBackend()
        await backend.seed(scriptPubkey: fundingAddress.scriptPubkey(), utxos: [
            BitcoinUTXO(
                txid: funding.txid,
                vout: 1,
                valueSats: 100_000,
                scriptPubkey: fundingAddress.scriptPubkey(),
                chain: 0,
                index: 0,
                confirmed: true
            ),
        ])
        await backend.seedRawTransaction(txid: funding.txid, raw: funding.raw)

        let client = BitcoinClient(backend: backend)
        let builder = BitcoinTransactionBuilder(client: client)

        let psbt = try await builder.buildTransfer(
            sender: sender, recipient: recipient, amount: BigUInt(50_000), token: nil, options: []
        )
        let signer = try BitcoinPKeySigner(descriptor: sender, seed: senderSeed, derivationPath: senderPath)
        let finalized = try await signer.sign(transaction: psbt)

        #expect(finalized.count > 60)
        #expect(finalized.prefix(4) == Data([0x02, 0x00, 0x00, 0x00]))
    }

    @Test func buildTransferRejectsANonNilToken() async throws {
        let (sender, _, _) = try makeAccount(network: .regtest, scriptType: .p2wpkh)
        let (recipient, _, _) = try makeAccount(network: .regtest, scriptType: .p2wpkh)

        let client = BitcoinClient(backend: MockBitcoinBackend())
        let builder = BitcoinTransactionBuilder(client: client)

        await #expect(throws: BlockchainTransactionBuilderError.self) {
            _ = try await builder.buildTransfer(
                sender: sender, recipient: recipient, amount: BigUInt(1), token: "not-nil", options: []
            )
        }
    }

    @Test func buildTransferThrowsInsufficientFundsWhenNoUtxosExist() async throws {
        let (sender, _, _) = try makeAccount(network: .regtest, scriptType: .p2wpkh)
        let (recipient, _, _) = try makeAccount(network: .regtest, scriptType: .p2wpkh)

        let client = BitcoinClient(backend: MockBitcoinBackend())
        let builder = BitcoinTransactionBuilder(client: client)

        await #expect(throws: BlockchainTransactionBuilderError.self) {
            _ = try await builder.buildTransfer(
                sender: sender, recipient: recipient, amount: BigUInt(50_000), token: nil, options: []
            )
        }
    }

    @Test func signerInitRejectsASingleAddressDescriptor() throws {
        let seed = Mnemonic.generate().toSeed()
        let watchOnly = try BitcoinDescriptor(
            address: try makeAccount(network: .regtest, scriptType: .p2wpkh).descriptor.deriveAddress(chain: 0, index: 0).string(),
            network: .regtest
        )
        let path = try DerivationPath.bitcoinAccount(network: .regtest, scriptType: .p2wpkh, accountIndex: 0)

        #expect(throws: WalletKitError.self) {
            _ = try BitcoinPKeySigner(descriptor: watchOnly, seed: seed, derivationPath: path)
        }
    }
}
