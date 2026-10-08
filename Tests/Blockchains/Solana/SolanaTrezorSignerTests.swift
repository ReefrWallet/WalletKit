import Foundation
import Testing
@testable import WalletKit

struct SolanaTrezorSignerTests {
    @Test func derivesAndSignsANativeTransferWithAConnectedDevice() async throws {
        try await withExclusiveHardwareAccess {
            let manager = HardwareDeviceManager()
            let devices = try await manager.scan()
            guard let info = devices.first else {
                return
            }

            let device = try await manager.connect(info, delegate: RecordingHardwareDeviceDelegate())
            let signer = try await SolanaTrezorSigner(
                network: .devnet,
                device: device,
                derivationPath: try DerivationPath(string: "m/44'/501'/0'/0'")
            )

            let sender = try signer.address()
            let recipient = try SolanaAddress(rawBytes: Data(repeating: 0x11, count: 32))

            let message = try SolanaMessage.compile(
                payer: sender,
                instructions: [SystemProgram.transfer(from: sender, to: recipient, lamports: 1)],
                recentBlockhash: Data(repeating: 0x22, count: 32)
            )

            let envelope = SolanaUnsignedTransaction(message: message.serialize())
            let payload = try JSONEncoder().encode(envelope)

            let signature = try await signer.sign(transaction: payload)
            #expect(signature.count == 64)
            #expect(signer.account.publicKey.verify(signature: signature, message: message.serialize()))
        }
    }

    @Test func signsAnOffChainMessageWithAConnectedDevice() async throws {
        try await withExclusiveHardwareAccess {
            let manager = HardwareDeviceManager()
            let devices = try await manager.scan()
            guard let info = devices.first else {
                return
            }

            let device = try await manager.connect(info, delegate: RecordingHardwareDeviceDelegate())
            let signer = try await SolanaTrezorSigner(
                network: .devnet,
                device: device,
                derivationPath: try DerivationPath(string: "m/44'/501'/0'/0'")
            )

            let text = "Example solana:signMessage message"
            let signature = try await signer.sign(message: .solanaMessage(Data(text.utf8)))
            #expect(signature.count == 64)

            // The device signs its OCMS v1 serialization, not the raw text.
            let signed = SolanaTrezorSigner.offchainMessageBytes(text, signer: try signer.address())
            #expect(signer.account.publicKey.verify(signature: signature, message: signed))
        }
    }

    @Test func offchainMessageBytesMatchTheOCMSv1Layout() throws {
        let signer = try SolanaAddress(rawBytes: Data(repeating: 0x07, count: 32))
        let bytes = SolanaTrezorSigner.offchainMessageBytes("hi", signer: signer)

        #expect(bytes.prefix(16) == Data([0xFF]) + Data("solana offchain".utf8))
        #expect(bytes[16] == 1) // version
        #expect(bytes[17] == 1) // signer count
        #expect(bytes[18 ..< 50] == Data(repeating: 0x07, count: 32))
        #expect(bytes.suffix(2) == Data("hi".utf8))
        #expect(bytes.count == 52)
    }

    @Test func signMessageRejectsANonSolanaMessageKind() async throws {
        try await withExclusiveHardwareAccess {
            let manager = HardwareDeviceManager()
            let devices = try await manager.scan()
            guard let info = devices.first else {
                return
            }

            let device = try await manager.connect(info, delegate: RecordingHardwareDeviceDelegate())
            let signer = try await SolanaTrezorSigner(
                network: .devnet,
                device: device,
                derivationPath: try DerivationPath(string: "m/44'/501'/0'/0'")
            )

            await #expect(throws: WalletKitError.self) {
                _ = try await signer.sign(message: .ethereumPersonal(Data("nope".utf8)))
            }
        }
    }
}
