import Foundation
import Testing
@testable import WalletKit
import WalletKitRust

struct TronTrezorSignerTests {
    @Test func derivesAndSignsANativeTransferWithAConnectedDevice() async throws {
        try await withExclusiveHardwareAccess {
            let manager = HardwareDeviceManager()
            let devices = try await manager.scan()
            guard let info = devices.first else {
                return
            }

            let device = try await manager.connect(info, delegate: RecordingHardwareDeviceDelegate())
            let signer = try await TronTrezorSigner(
                network: .testnet,
                device: device,
                derivationPath: TestAccountFactory.bip44Path(coinType: 195)
            )

            let sender = try signer.address()
            let recipient = try TronAddress(string: "TGtcCdz2aV9vvCEtQL5BY8z2BnLi4oJ3sK")
            let now = UInt64(Date().timeIntervalSince1970 * 1_000)
            let transaction: [String: Any] = [
                "raw_data": [
                    "contract": [[
                        "type": "TransferContract",
                        "parameter": ["value": [
                            "owner_address": sender.rawBytes.hexEncoded,
                            "to_address": recipient.rawBytes.hexEncoded,
                            "amount": 1
                        ]]
                    ]],
                    "expiration": now + 600_000,
                    "ref_block_bytes": "e942",
                    "ref_block_hash": "6394747da9fee421",
                    "timestamp": now
                ]
            ]
            let payload = try JSONSerialization.data(withJSONObject: transaction)
            let signature = try await signer.sign(transaction: payload)
            #expect(signature.count == 65)
            #expect((27...30).contains(signature.last ?? 0))

            let transactionJSON = try #require(String(data: payload, encoding: .utf8))
            let rawData = try tronRawData(transaction: transactionJSON)
            #expect(signer.account.publicKey.verify(signature: Data(signature.dropLast()), message: rawData))
        }
    }
}

private extension Data {
    var hexEncoded: String {
        map { String(format: "%02x", $0) }.joined()
    }
}
