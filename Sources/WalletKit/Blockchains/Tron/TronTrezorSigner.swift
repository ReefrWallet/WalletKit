import Foundation

/// A Tron signer backed by Trezor's native `TronSignTx` protocol.
///
/// The device receives the structured TronGrid transaction fields and shows
/// the transfer or TRC-20 call on its trusted screen before returning the
/// recoverable 65-byte signature accepted by `broadcasttransaction`.
public final class TronTrezorSigner: Signer {
    public typealias Address = TronAddress

    public let account: Account

    private let device: HardwareDevice

    public init(
        network: TronNetwork = .mainnet,
        device: HardwareDevice,
        derivationPath: DerivationPath
    ) async throws {
        let publicKey = try await device.publicKey(path: derivationPath, curve: .secp256k1)
        self.device = device
        account = Account(
            blockchain: .tron(network),
            derivationPath: derivationPath,
            curve: .secp256k1,
            source: device.source,
            publicKey: publicKey
        )
    }

    public func address() throws -> TronAddress {
        try TronAddress(publicKey: account.publicKey)
    }

    public func sign(transaction: Data) async throws -> Data {
        guard device.isConnected else {
            throw WalletKitError.deviceDisconnected
        }

        guard let transaction = String(data: transaction, encoding: .utf8) else {
            throw WalletKitError.signingFailed(reason: "A Trezor Tron transaction must be valid UTF-8 JSON.")
        }

        return try await remappingWalletKitError {
            try await device.raw.tronSignTx(path: account.derivationPath.raw, transaction: transaction)
        }
    }
}
