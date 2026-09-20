// Spec-driven test for EthereumTrezorSigner.
//
// EthereumTrezorSigner's decode (signTx(from:)) and re-encode
// (signedTransaction(_:signature:)) halves are real, Rust-backed operations
// shared with EthereumPKeySigner's software path via EthereumSignerFfi.
// sign(transaction:) composes them around a real device conversation over
// the walletkit-trezor USB transport. Constructing a signer still requires
// a connected device to read its public key, so these tests scan first and
// return early when none is available.
//
// Runs the same ethereum-tx.json vectors as EthereumPKeySignerTests. The
// round-trip test stands the "device-produced" signature in for by computing
// it straight from the vector's private key via the same
// `EthereumSignerFfi.signature(signingData:privateKey:)` a real device
// conversation produces the equivalent of — this exercises decode/re-encode
// against known-good expected output without needing the connected device's
// own (unknown) private key to match a vector. The other test calls
// sign(transaction:) against the real device end to end instead, which can
// only assert well-formedness, not byte-for-byte equality with a vector.

import Foundation
import Testing
@testable import WalletKit
import WalletKitRust

private struct EthereumTxVector: Decodable, Sendable, CustomTestStringConvertible {
    let label: String
    let privateKey: String
    let chainId: UInt64
    let signingDataHex: String
    let signedTxHex: String

    var testDescription: String { label }
}

private func loadVectors() -> [EthereumTxVector] {
    let url = Bundle.module.url(forResource: "ethereum-tx", withExtension: "json")!
    // swiftlint:disable force_try
    let data = try! Data(contentsOf: url)
    return try! JSONDecoder().decode([EthereumTxVector].self, from: data)
    // swiftlint:enable force_try
}

private extension String {
    var hexDecoded: Data {
        let hex = hasPrefix("0x") ? String(dropFirst(2)) : self
        var data = Data(capacity: hex.count / 2)
        var index = hex.startIndex
        while index < hex.endIndex {
            let next = hex.index(index, offsetBy: 2, limitedBy: hex.endIndex) ?? hex.endIndex
            data.append(UInt8(hex[index..<next], radix: 16)!)
            index = next
        }
        return data
    }
}

private extension Data {
    var hexEncoded: String {
        "0x" + map { String(format: "%02x", $0) }.joined()
    }
}

struct EthereumTrezorSignerTests {
    fileprivate static let txVectors: [EthereumTxVector] = loadVectors()

    @Test func decodeAndEncodeRoundTripEveryVectorThroughAConnectedDevice() async throws {
        try await withExclusiveHardwareAccess {
            let manager = HardwareDeviceManager()
            let devices = try await manager.scan()
            guard let info = devices.first else {
                return
            }

            let device = try await manager.connect(info, delegate: RecordingHardwareDeviceDelegate())
            let derivationPath = TestAccountFactory.bip44Path(coinType: 60)

            for vector in Self.txVectors {
                let signer = try await EthereumTrezorSigner(
                    chainId: vector.chainId,
                    device: device,
                    derivationPath: derivationPath
                )

                let signingData = vector.signingDataHex.hexDecoded
                let privateKey = try PrivateKey(curve: .secp256k1, rawBytes: vector.privateKey.hexDecoded)
                let ffi = EthereumSignerFfi(chainId: vector.chainId)

                if signingData.first == 0x02 {
                    let signTx = try signer.signTxEIP1559(from: signingData)
                    #expect(signTx.chainId == vector.chainId)

                    // Stands in for a real device signature — no walletkit-trezor
                    // transport exists yet.
                    let raw = try ffi.signatureEip1559(signingData: signingData, privateKey: privateKey.raw)
                    let signature = EthereumEIP1559Signature(yParity: raw.yParity, r: raw.r, s: raw.s)

                    let signed = try signer.signedTransactionEIP1559(signingData, signature: signature)
                    #expect(signed.hexEncoded == vector.signedTxHex, "\(vector.label)")
                } else {
                    let signTx = try signer.signTx(from: signingData)
                    #expect(signTx.chainId == vector.chainId)

                    // Stands in for a real device signature — no walletkit-trezor
                    // transport exists yet.
                    let raw = try ffi.signature(signingData: signingData, privateKey: privateKey.raw)
                    let signature = EthereumSignature(v: raw.v, r: raw.r, s: raw.s)

                    let signed = try signer.signedTransaction(signingData, signature: signature)
                    #expect(signed.hexEncoded == vector.signedTxHex, "\(vector.label)")
                }
            }
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
            let signer = try await EthereumTrezorSigner(
                device: device,
                derivationPath: TestAccountFactory.bip44Path(coinType: 60)
            )

            // The connected device's own key won't match the vector's, so
            // this can't assert byte-for-byte equality against
            // `signedTxHex` the way the decode/re-encode round trip above
            // does — only that a real device conversation produces a
            // well-formed signed transaction (which, since `encodeSigned`
            // validates `v`/`r`/`s` strictly, also proves the device
            // returned a valid EIP-155 signature for this chain).
            let signed = try await signer.sign(transaction: Self.txVectors[0].signingDataHex.hexDecoded)
            #expect(!signed.isEmpty)
        }
    }
}
