import BigInt
import Foundation
import WalletKitRust

/// Blockfrost-backed read client for CIP-1852 Cardano accounts.
///
/// The client covers account discovery, history, and signed-CBOR submission.
/// Transfer construction remains separate because it requires UTxO selection
/// and CBOR witness assembly.
public struct CardanoClient: BlockchainClientProtocol, Sendable {
    public typealias Address = CardanoAccountDescriptor

    private let endpoint: URL
    private let projectId: String?
    private let session: URLSession

    public init(endpoint: URL, projectId: String?, session: URLSession = .shared) {
        self.endpoint = endpoint
        self.projectId = projectId?.trimmingCharacters(in: .whitespacesAndNewlines)
        self.session = session
    }

    public func broadcast(transaction _: Data, signature: Data) async throws -> String {
        guard !signature.isEmpty else {
            throw WalletKitError.signingFailed(reason: "Cardano transaction CBOR is empty.")
        }

        guard let projectId, !projectId.isEmpty else {
            throw WalletKitError.internalError(message: "Set a Blockfrost project ID before using Cardano.")
        }

        var request = URLRequest(url: endpoint.appending(path: "tx/submit"))

        request.httpBody = signature
        request.httpMethod = "POST"
        request.setValue("application/cbor", forHTTPHeaderField: "Content-Type")
        request.setValue(projectId, forHTTPHeaderField: "project_id")

        let (data, response) = try await session.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse, (200..<300).contains(httpResponse.statusCode) else {
            throw WalletKitError.internalError(message: "Blockfrost rejected Cardano transaction submission.")
        }

        guard let identifier = String(data: data, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines), !identifier.isEmpty else {
            throw WalletKitError.internalError(message: "Blockfrost returned no Cardano transaction ID.")
        }

        return identifier
    }

    /// Builds an ADA or native-asset transfer from UTxOs held at the current
    /// receive address. A token output requires an explicit lovelace amount.
    func buildTransfer(
        _ owner: CardanoAccountDescriptor,
        recipientLovelace: UInt64?,
        recipient: CardanoAddress,
        amount: BigUInt,
        token: String?
    ) async throws -> CardanoUnsignedTransactionFfi {
        guard amount <= BigUInt(UInt64.max) else {
            throw BlockchainTransactionBuilderError.amountTooLarge
        }

        let utxos = try await accountUTxOs(owner).compactMap { utxo -> CardanoUtxoFfi? in
            guard
                utxo.address == owner.receiveAddress.string,
                let lovelace = utxo.amount.first(where: { $0.unit == "lovelace" }),
                let hash = try? Data(hexString: utxo.txHash)
            else {
                return nil
            }

            let assets = utxo.amount.compactMap { asset -> CardanoAssetFfi? in
                guard asset.unit != "lovelace", let parsed = CardanoAssetId(unit: asset.unit) else {
                    return nil
                }

                return CardanoAssetFfi(name: parsed.name, policyId: parsed.policyId, quantity: asset.quantity)
            }

            return CardanoUtxoFfi(
                address: utxo.address,
                assets: assets,
                lovelace: lovelace.quantity,
                outputIndex: utxo.outputIndex,
                txHash: hash
            )
        }

        let parameters: ProtocolParameters = try await get("epochs/latest/parameters")
        let selectedAsset: CardanoAssetFfi?

        if let token {
            guard let asset = CardanoAssetId(unit: token) else {
                throw WalletKitError.invalidAddress(reason: "Invalid Cardano asset identifier")
            }

            selectedAsset = asset.ffi(quantity: amount.description)
        } else {
            selectedAsset = nil
        }

        let result = try remappingWalletKitError {
            try cardanoBuildTransfer(
                amount: amount.description,
                changeAddress: owner.receiveAddress.string,
                recipientLovelace: token == nil ? amount.description : String(recipientLovelace ?? 0),
                protocolParameters: parameters.ffi,
                recipient: recipient.string,
                token: selectedAsset,
                utxos: utxos
            )
        }

        return result
    }

    public func estimateFee(for request: FeeEstimateRequest<CardanoAccountDescriptor>?) async throws -> FeeEstimate {
        throw WalletKitError.unsupportedFeature
    }

    public func getAllBalances(_ owner: CardanoAccountDescriptor) async throws -> [String: BigUInt] {
        let entries = try await accountUTxOs(owner)

        return entries.reduce(into: [:]) { balances, entry in
            for amount in entry.amount {
                guard let quantity = BigUInt(amount.quantity) else {
                    continue
                }

                balances[amount.unit, default: 0] += quantity
            }
        }
    }

    public func getBalance(_ owner: CardanoAccountDescriptor, token: String) async throws -> BigUInt {
        try await getAllBalances(owner)[token] ?? 0
    }

    public func getBalances(
        _ owner: CardanoAccountDescriptor,
        tokens: [String]
    ) async throws -> [String: BigUInt] {
        let allBalances = try await getAllBalances(owner)

        return tokens.reduce(into: [:]) { balances, token in
            balances[token] = allBalances[token] ?? 0
        }
    }

    public func getNativeBalance(_ owner: CardanoAccountDescriptor) async throws -> BigUInt {
        try await getAllBalances(owner)["lovelace"] ?? 0
    }

    public func getTokenInfo(_ token: String?) async throws -> TokenInfo {
        guard let token, token != "lovelace" else {
            return .ada
        }

        let asset: Asset = try await get("assets/\(token)")
        let metadata = asset.onchainMetadata ?? asset.metadata

        return TokenInfo(
            decimals: metadata?.decimals ?? 0,
            name: metadata?.name ?? token,
            isNative: false,
            symbol: metadata?.ticker ?? token
        )
    }

    public func getTokenPrice(_ token: String?) async throws -> Decimal {
        throw WalletKitError.unsupportedFeature
    }

    public func isActiveAccount(_ owner: CardanoAccountDescriptor) async throws -> Bool {
        !(try await getAllBalances(owner)).isEmpty
    }

    public func isSupported(_ feature: BlockchainClientFeature) -> Bool {
        switch feature {
        case .allBalances, .transactionHistory:
            true
        case .feeEstimation, .multipleBalances, .transactionSubscription:
            false
        }
    }
}

private struct CardanoAssetId {
    let name: Data
    let policyId: Data

    init?(unit: String) {
        guard unit.count >= 56 else {
            return nil
        }

        let policyText = String(unit.prefix(56))
        let nameText = String(unit.dropFirst(56))

        guard let policyID = try? Data(hexString: policyText), let name = try? Data(hexString: nameText) else {
            return nil
        }

        self.name = name
        self.policyId = policyID
    }

    func ffi(quantity: String) -> CardanoAssetFfi {
        CardanoAssetFfi(name: name, policyId: policyId, quantity: quantity)
    }
}

private extension CardanoClient {
    struct ProtocolParameters: Decodable {
        let coinsPerUtxoSize: UInt64
        let keyDeposit: UInt64
        let maxTxSize: UInt32
        let maxValSize: UInt32
        let minFeeA: UInt64
        let minFeeB: UInt64
        let poolDeposit: UInt64

        var ffi: CardanoProtocolParametersFfi {
            CardanoProtocolParametersFfi(
                coinsPerUtxoByte: coinsPerUtxoSize,
                keyDeposit: keyDeposit,
                maxTxSize: maxTxSize,
                maxValueSize: maxValSize,
                minFeeA: minFeeA,
                minFeeB: minFeeB,
                poolDeposit: poolDeposit
            )
        }

        enum CodingKeys: String, CodingKey {
            case coinsPerUtxoSize = "coins_per_utxo_size"
            case keyDeposit = "key_deposit"
            case maxTxSize = "max_tx_size"
            case maxValSize = "max_val_size"
            case minFeeA = "min_fee_a"
            case minFeeB = "min_fee_b"
            case poolDeposit = "pool_deposit"
        }
    }

    struct Amount: Decodable {
        let quantity: String
        let unit: String
    }

    struct Asset: Decodable {
        let metadata: Metadata?
        let onchainMetadata: Metadata?

        enum CodingKeys: String, CodingKey {
            case metadata
            case onchainMetadata = "onchain_metadata"
        }
    }

    struct Metadata: Decodable {
        let decimals: UInt8?
        let name: String?
        let ticker: String?
    }

    struct UTxO: Decodable {
        let address: String
        let amount: [Amount]
        let outputIndex: UInt32
        let txHash: String

        enum CodingKeys: String, CodingKey {
            case address
            case amount
            case outputIndex = "output_index"
            case txHash = "tx_hash"
        }
    }

    func accountUTxOs(_ owner: CardanoAccountDescriptor) async throws -> [UTxO] {
        let count = 100
        var entries: [UTxO] = []
        var page = 1

        while true {
            let result: [UTxO]

            do {
                result = try await get(
                    "accounts/\(owner.stakeAddress)/utxos",
                    query: [
                        URLQueryItem(name: "count", value: "\(count)"),
                        URLQueryItem(name: "page", value: "\(page)")
                    ]
                )
            } catch HTTPError.notFound {
                return []
            }

            entries.append(contentsOf: result)

            guard result.count == count else {
                return entries
            }

            page += 1
        }
    }
}

// Internal rather than private: `CardanoClient+TransactionHistory` reads
// Blockfrost through the same two helpers.
extension CardanoClient {
    func get<Response: Decodable>(_ path: String, query: [URLQueryItem] = []) async throws -> Response {
        guard let projectId, !projectId.isEmpty else {
            throw WalletKitError.internalError(message: "Set a Blockfrost project ID before using Cardano.")
        }

        guard var components = URLComponents(url: endpoint.appending(path: path), resolvingAgainstBaseURL: false) else {
            throw WalletKitError.internalError(message: "Cannot construct Blockfrost URL.")
        }

        components.queryItems = query.isEmpty ? nil : query

        guard let url = components.url else {
            throw WalletKitError.internalError(message: "Cannot construct Blockfrost URL.")
        }

        let data = try await responseData(url: url, path: path, projectId: projectId)
        return try JSONDecoder().decode(Response.self, from: data)
    }

    func responseData(url: URL, path: String, projectId: String) async throws -> Data {
        var request = URLRequest(url: url)
        request.setValue(projectId, forHTTPHeaderField: "project_id")

        let (data, response) = try await session.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw WalletKitError.internalError(message: "Blockfrost returned an invalid response.")
        }

        if httpResponse.statusCode == 404 {
            throw HTTPError.notFound
        }

        guard (200..<300).contains(httpResponse.statusCode) else {
            throw WalletKitError.internalError(message: "Blockfrost rejected \(path).")
        }

        return data
    }
}

private enum HTTPError: Swift.Error {
    case notFound
}
