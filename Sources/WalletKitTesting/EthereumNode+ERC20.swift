import BigInt
import Foundation
import WalletKit

/// ERC-20 fixtures for local-node tests.
extension EthereumNode {
    /// Deploys a minimal test ERC-20 ("Mock USDC", symbol `USDC`, 6 decimals,
    /// unrestricted `mint(address,uint256)`) and returns its address.
    public func deployMockERC20(signer: EthereumPKeySigner) async throws -> EthereumAddress {
        let hash = try await send(signer: signer, to: nil, data: Self.mockERC20CreationBytecode, gasLimit: 1_000_000)

        guard let address = try await waitForReceipt(hash).contractAddress else {
            throw EthereumLaunchError(description: "mock ERC-20 deployment produced no contract address")
        }

        return try EthereumAddress(string: address)
    }

    /// Sends `amount` of the ERC-20 at `token` with `transfer(address,uint256)`.
    public func transferERC20(
        signer: EthereumPKeySigner,
        token: EthereumAddress,
        recipient: EthereumAddress,
        amount: BigUInt
    ) async throws -> String {
        try await send(
            signer: signer,
            to: token,
            data: EthereumABI.encodeCall(
                selector: EthereumABI.selector("transfer(address,uint256)"),
                parameters: [.address(recipient), .uint256(amount)]
            ),
            gasLimit: 100_000
        )
    }

    /// Creation bytecode of the contract `deployMockERC20(signer:)` deploys — the same
    /// mock WalletKit's `EthereumAnvilTests` use.
    private static let mockERC20CreationBytecode: Data = {
        let hex = [
            "6080604052348015600e575f5ffd5b506103ae8061001c5f395ff3fe608060405234801561000f575f5ffd5b506004361061",
            "0060575f3560e01c806306fdde0314610064578063313ce567146100a257806340c10f19146100bc57806370a08231146100",
            "d157806395d89b41146100fe578063a9059cbb14610121575b5f5ffd5b61008c604051806040016040528060098152602001",
            "684d6f636b205553444360b81b81525081565b60405161009991906102a6565b60405180910390f35b6100aa600681565b60",
            "405160ff9091168152602001610099565b6100cf6100ca3660046102f6565b610144565b005b6100f06100df36600461031e",
            "565b5f6020819052908152604090205481565b604051908152602001610099565b61008c6040518060400160405280600481",
            "52602001635553444360e01b81525081565b61013461012f3660046102f6565b6101b4565b60405190151581526020016100",
            "99565b6001600160a01b0382165f908152602081905260408120805483929061016b908490610352565b9091555050604051",
            "8181526001600160a01b038316905f907fddf252ad1be2c89b69c2b068fc378daa952ba7f163c4a11628f55a4df523b3ef90",
            "60200160405180910390a35050565b335f9081526020819052604081205482111561020d5760405162461bcd60e51b815260",
            "2060048201526014602482015273696e73756666696369656e742062616c616e636560601b60448201526064016040518091",
            "0390fd5b335f908152602081905260408120805484929061022b908490610365565b90915550506001600160a01b0383165f",
            "9081526020819052604081208054849290610257908490610352565b90915550506040518281526001600160a01b03841690",
            "33907fddf252ad1be2c89b69c2b068fc378daa952ba7f163c4a11628f55a4df523b3ef9060200160405180910390a3506001",
            "5b92915050565b602081525f82518060208401528060208501604085015e5f604082850101526040601f19601f8301168401",
            "0191505092915050565b80356001600160a01b03811681146102f1575f5ffd5b919050565b5f5f6040838503121561030757",
            "5f5ffd5b610310836102db565b946020939093013593505050565b5f6020828403121561032e575f5ffd5b610337826102db",
            "565b9392505050565b634e487b7160e01b5f52601160045260245ffd5b808201808211156102a0576102a061033e565b8181",
            "03818111156102a0576102a061033e56fea26469706673582212200b59cd1cd101f07cbeba3ebf884340311a05cb5e06312b",
            "51ea59aabc144d458064736f6c63430008230033"
        ].joined()

        return Data(stride(from: 0, to: hex.count, by: 2).map { offset in
            let start = hex.index(hex.startIndex, offsetBy: offset)
            return UInt8(hex[start ..< hex.index(start, offsetBy: 2)], radix: 16) ?? 0
        })
    }()
}
