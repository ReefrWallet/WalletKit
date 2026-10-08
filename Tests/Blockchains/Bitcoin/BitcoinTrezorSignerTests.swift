// Spec-driven test for BitcoinTrezorSigner.
//
// Building a BitcoinTrezorSigner needs two real device reads (the master
// public key, then the account-level xpub) before any signing happens, so
// both tests here scan for a connected device first and return early when
// none is available — mirroring EthereumTrezorSignerTests.
//
// The signing test builds a synthetic-but-well-formed single-input PSBT
// (a self-consistent fake funding transaction via `makeFundingTransaction`,
// real derived scriptPubkey/public key) rather than a funded UTXO: Trezor's
// SignTx flow signs whatever the PSBT declares without validating it
// against the real chain — it does, however, require the funding
// transaction's own bytes (`non_witness_utxo`) to independently verify the
// spent amount, which is why this can't get away with an arbitrary txid
// the way the Ethereum equivalent test's signing data can.

import Foundation
import Testing
@testable import WalletKit
import WalletKitRust

struct BitcoinTrezorSignerTests {
    @Test func descriptorMatchesTheAccountLevelXpubReadFromAConnectedDevice() async throws {
        try await withExclusiveHardwareAccess {
            let manager = HardwareDeviceManager()
            let devices = try await manager.scan()
            guard let info = devices.first else {
                return
            }

            let device = try await manager.connect(info, delegate: RecordingHardwareDeviceDelegate())
            let signer = try await BitcoinTrezorSigner(network: .testnet, scriptType: .p2wpkh, device: device)

            let descriptor = try signer.address()
            #expect(descriptor.scriptType == .p2wpkh)
            #expect(descriptor.network == .testnet)
            #expect(descriptor.string.hasPrefix("wpkh("))

            // Derives locally, with no further device round-trip.
            let address = try descriptor.deriveAddress(chain: 0, index: 0)
            #expect(!address.scriptPubkey().isEmpty)
        }
    }

    @Test func signProducesARealSignedTransactionFromAConnectedDevice() async throws {
        try await withExclusiveHardwareAccess {
            let manager = HardwareDeviceManager()
            let devices = try await manager.scan()
            guard let info = devices.first else {
                return
            }

            let device = try await manager.connect(info, delegate: RecordingHardwareDeviceDelegate())
            let signer = try await BitcoinTrezorSigner(network: .testnet, scriptType: .p2wpkh, device: device)
            let descriptor = try signer.address()

            let ownAddress = try descriptor.deriveAddress(chain: 0, index: 0)
            let ownPublicKey = try descriptor.derivePublicKey(chain: 0, index: 0)
            let recipient = try descriptor.deriveAddress(chain: 0, index: 1)
            let funding = makeFundingTransaction(
                scriptPubkey: ownAddress.scriptPubkey(), valueSats: 100_000, nonce: 0xF0
            )

            let input = BitcoinPsbtInputFfi(
                txid: funding.txid,
                vout: 0,
                valueSats: 100_000,
                scriptPubkey: ownAddress.scriptPubkey(),
                publicKey: ownPublicKey,
                masterFingerprint: descriptor.masterFingerprint,
                derivationPath: "\(descriptor.accountPath)/0/0",
                isTaproot: false,
                nonWitnessUtxo: funding.raw
            )

            let output = BitcoinPsbtOutputFfi(scriptPubkey: recipient.scriptPubkey(), valueSats: 90_000)
            let psbt = try bitcoinBuildUnsignedPsbt(inputs: [input], outputs: [output], locktime: 0)

            // The connected device's own key produced this signature, so
            // this can't assert byte-for-byte equality against a fixed
            // vector — only that a real device conversation produces a
            // well-formed, finalized raw transaction.
            let signed = try await signer.sign(transaction: psbt)
            #expect(!signed.isEmpty)
        }
    }
}
