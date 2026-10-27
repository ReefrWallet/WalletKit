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
            let signer = try CardanoTrezorSigner(network: .preprod, path: .cardanoAccount(accountIndex: 0), device: device)
            let signed = try await signer.sign(transaction: request)

            #expect(!signed.isEmpty)
        }
    }

    @Test func signsADappTransactionWithAConnectedDevice() async throws {
        try await withExclusiveHardwareAccess {
            guard let device = try await connectedDevice() else {
                return
            }

            let descriptor = try await descriptor(device: device)
            let unsigned = try cardanoBuildTransfer(
                amount: "1000000",
                changeAddress: descriptor.receiveAddress.string,
                recipientLovelace: "1000000",
                protocolParameters: CardanoProtocolParametersFfi(
                    coinsPerUtxoByte: 4310,
                    keyDeposit: 2_000_000,
                    maxTxSize: 16_384,
                    maxValueSize: 5_000,
                    minFeeA: 44,
                    minFeeB: 155_381,
                    poolDeposit: 500_000_000
                ),
                recipient: try descriptor.address(role: 0, index: 1).string,
                token: nil,
                utxos: [CardanoUtxoFfi(
                    address: descriptor.receiveAddress.string,
                    assets: [],
                    lovelace: "5000000",
                    outputIndex: 0,
                    txHash: Data(repeating: 8, count: 32)
                )]
            )
            // What a dapp sends: the original body with an empty witness set.
            let transaction = Data([0x84]) + unsigned.transactionBody + Data([0xA0, 0xF5, 0xF6])
            let signer = try CardanoTrezorSigner(
                descriptor: descriptor,
                path: .cardanoAccount(accountIndex: 0),
                device: device
            )

            let witnesses = try await signer.signDappTransaction(
                transaction,
                paths: [CardanoSigningPathFfi(index: 0, role: 0)]
            )

            // A witness set holding only the device's vkey witness.
            #expect(witnesses.prefix(2) == Data([0xA1, 0x00]))
        }
    }

    @Test func signsCip8DataWithAConnectedDeviceAndMatchesTheSoftwareStructure() async throws {
        try await withExclusiveHardwareAccess {
            guard let device = try await connectedDevice() else {
                return
            }

            let descriptor = try await descriptor(device: device)
            let address = try cardanoAddressToBytes(address: descriptor.receiveAddress.string)
            let signer = try CardanoTrezorSigner(
                descriptor: descriptor,
                path: .cardanoAccount(accountIndex: 0),
                device: device
            )

            let signed = try await signer.signData(
                Data("hello reefr".utf8),
                address: address,
                path: CardanoSigningPathFfi(index: 0, role: 0)
            )

            #expect(signed.signature.first == 0x84) // COSE_Sign1
            #expect(signed.key.first == 0xA4) // COSE_Key
            #expect(signed.signature.range(of: Data("hello reefr".utf8)) != nil) // un-hashed payload
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
