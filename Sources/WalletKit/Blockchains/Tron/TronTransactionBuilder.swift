import BigInt
import Foundation

public struct TronTransactionBuilder: BlockchainTransactionBuilderProtocol {
    public typealias Address = TronAddress

    private let client: TronClient

    public init(client: TronClient) {
        self.client = client
    }

    public func buildTransfer(
        sender: TronAddress,
        recipient: TronAddress,
        amount: BigUInt,
        token: String?,
        options: [BlockchainTransactionBuilderOptions]
    ) async throws -> Data {
        let feeLimit = options.lazy.compactMap { option in
            if case let .tronFeeLimit(value) = option {
                return value
            }
            return nil
        }.first
        return try await client.buildTransfer(
            sender: sender,
            recipient: recipient,
            amount: amount,
            token: token,
            feeLimit: feeLimit
        )
    }
}
