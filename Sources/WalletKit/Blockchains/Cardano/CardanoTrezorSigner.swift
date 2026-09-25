import Foundation
import WalletKitRust

/// Signs Cardano ADA and native-asset envelopes through Trezor's structured
/// Cardano protocol. The device receives all inputs, outputs, assets, fee and
/// expiry fields and verifies its reconstructed body hash before witnesses are
/// returned to WalletKit.
public final class CardanoTrezorSigner {
    private let accountPath: DerivationPath
    private let device: HardwareDevice
    private let network: CardanoNetwork

    public init(network: CardanoNetwork, accountIndex: UInt32, device: HardwareDevice) throws {
        accountPath = try DerivationPath(string: "m/1852'/1815'/\(accountIndex)'")
        self.device = device
        self.network = network
    }

    public func sign(transaction: Data) async throws -> Data {
        guard device.isConnected else {
            throw WalletKitError.deviceDisconnected
        }

        let unsigned = try JSONDecoder().decode(CardanoUnsignedTransaction.self, from: transaction)
        let inputs = unsigned.inputs.map { CardanoInputFfi(outputIndex: $0.outputIndex, txHash: $0.txHash) }
        let outputs = try unsigned.outputs.map { output in
            CardanoOutputFfi(
                address: output.address,
                assets: try output.assets.map { asset in
                    guard let quantity = UInt64(asset.quantity) else {
                        throw WalletKitError.signingFailed(reason: "Cardano native asset quantity exceeds Trezor's supported range.")
                    }
                    return HardwareCardanoAssetFfi(name: asset.name, policyId: asset.policyId, quantity: quantity)
                },
                lovelace: try lovelace(output.lovelace)
            )
        }
        let witnessPaths = try unsigned.signingPaths.map { path in
            try DerivationPath(string: "\(accountPath.string)/\(path.role)/\(path.index)")
        }
        let request = CardanoSignTxFfi(
            bodyHash: try unsigned.transactionBodyHash(),
            fee: try lovelace(unsigned.fee),
            inputs: inputs,
            networkId: unsigned.networkId,
            outputs: outputs,
            protocolMagic: network.protocolMagic,
            ttl: unsigned.ttl,
            witnessPaths: witnessPaths.map(\.raw)
        )
        let witnesses = try await remappingWalletKitError {
            try await device.raw.cardanoSignTx(tx: request)
        }
        return try unsigned.assembled(witnesses: witnesses)
    }

    private func lovelace(_ value: String) throws -> UInt64 {
        guard let value = UInt64(value) else {
            throw WalletKitError.signingFailed(reason: "Cardano lovelace amount exceeds Trezor's supported range.")
        }
        return value
    }
}

private extension CardanoNetwork {
    var protocolMagic: UInt32 {
        switch self {
        case .mainnet: 764_824_073
        case .preprod: 1
        }
    }
}
