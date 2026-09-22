import Foundation
import Testing
@testable import WalletKit
import WalletKitRust

/// Hardware integration coverage. The transaction uses a structurally valid,
/// synthetic UTxO and is never broadcast; approving it on the device only
/// proves the Cardano signing protocol end to end.
@Suite(.serialized, .timeLimit(.minutes(2)))
struct CardanoTrezorSignerTests {
    @Test func derivesTheCip1852ReceiveAddressFromAConnectedDevice() async throws {
        try await withExclusiveHardwareAccess {
            guard let device = try await connectedDevice() else {
                return
            }
            let descriptor = try await descriptor(device: device)

            #expect(descriptor.network == .preprod)
            #expect(descriptor.receiveAddress.string.hasPrefix("addr_test"))
        }
    }

    @Test func signsANativeAssetTransactionWithAConnectedDevice() async throws {
        try await withExclusiveHardwareAccess {
            guard let device = try await connectedDevice() else {
                return
            }
            let descriptor = try await descriptor(device: device)
            let recipient = try descriptor.address(role: 0, index: 1)
            let asset = CardanoAssetFfi(
                name: Data("TEST".utf8),
                policyId: Data(repeating: 9, count: 28),
                quantity: "3"
            )
            let unsigned = try cardanoBuildTransfer(
                amount: "3",
                changeAddress: descriptor.receiveAddress.string,
                recipientLovelace: "2000000",
                protocolParameters: CardanoProtocolParametersFfi(
                    coinsPerUtxoByte: 4310,
                    keyDeposit: 2_000_000,
                    maxTxSize: 16_384,
                    maxValueSize: 5_000,
                    minFeeA: 44,
                    minFeeB: 155_381,
                    poolDeposit: 500_000_000
                ),
                recipient: recipient.string,
                token: asset,
                utxos: [CardanoUtxoFfi(
                    address: descriptor.receiveAddress.string,
                    assets: [CardanoAssetFfi(
                        name: asset.name,
                        policyId: asset.policyId,
                        quantity: "10"
                    )],
                    lovelace: "5000000",
                    outputIndex: 0,
                    txHash: Data(repeating: 8, count: 32)
                )]
            )
            let request = try JSONEncoder().encode(CardanoUnsignedTransaction(unsigned))
            let signer = try CardanoTrezorSigner(network: .preprod, accountIndex: 0, device: device)
            let signed = try await signer.sign(transaction: request)

            #expect(!signed.isEmpty)
        }
    }
}

private extension CardanoTrezorSignerTests {
    func connectedDevice() async throws -> HardwareDevice? {
        let manager = HardwareDeviceManager()
        let devices = try await manager.scan()
        guard let info = devices.first else {
            if ProcessInfo.processInfo.environment["TREZOR_INTEGRATION_REQUIRED"] == "1" {
                Issue.record("No Trezor is visible to HardwareDeviceManager.scan().")
            }
            return nil
        }
        return try await manager.connect(info, delegate: RecordingHardwareDeviceDelegate())
    }

    func descriptor(device: HardwareDevice) async throws -> CardanoAccountDescriptor {
        let path = try DerivationPath(string: "m/1852'/1815'/0'")
        let xpub = try await device.cardanoXpub(path: path)
        return try CardanoAccountDescriptor(xpub: xpub, network: .preprod)
    }
}
