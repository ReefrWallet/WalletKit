import Alamofire
import BigInt
import Foundation
import Moya
import WalletKitRust

/// Blockfrost-backed read client for CIP-1852 Cardano accounts.
///
/// The client covers account discovery, history, and signed-CBOR submission.
/// Transfer construction remains separate because it requires UTxO selection
/// and CBOR witness assembly.
///
/// Rate-limit handling (retrying 429/503 with backoff; no proactive pacing
/// until Blockfrost's real plan/key-tier limit is confirmed — see
/// ``RateGateRegistry``) comes from the shared registry, looked up by this
/// client's own endpoint.
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

    public func broadcast(transaction: Data, signature: Data) async throws -> String {
        guard !signature.isEmpty else {
            throw WalletKitError.signingFailed(reason: "Cardano transaction CBOR is empty.")
        }

        guard let projectId, !projectId.isEmpty else {
            throw WalletKitError.internalError(message: "Set a Blockfrost project ID before using Cardano.")
        }

        do {
            let data = try await requestData(
                .submit(endpoint: endpoint, projectId: projectId, cbor: signature),
                path: "tx/submit"
            )

            guard let identifier = String(data: data, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines), !identifier.isEmpty else {
                throw WalletKitError.internalError(message: "Blockfrost returned no Cardano transaction ID.")
            }

            return identifier
        } catch let WalletKitError.internalError(message) where Self.looksLikeAlreadySubmitted(message) {
            // A 429/503 retry can land on this after the first attempt
            // actually landed. The canonical tx hash is the *unsigned*
            // transaction body's hash — not the complete signed CBOR,
            // which also includes the witness set — recovered from
            // `transaction`, the JSON-encoded `CardanoUnsignedTransaction`
            // envelope `CardanoTransactionBuilder` produced, instead of
            // trusting a possibly-inconsistent second response.
            let unsigned = try JSONDecoder().decode(CardanoUnsignedTransaction.self, from: transaction)
            return try unsigned.transactionBodyHash().map { String(format: "%02x", $0) }.joined()
        }
    }

    private static func looksLikeAlreadySubmitted(_ message: String) -> Bool {
        ["already exists", "already submitted", "already in the mempool", "already known"].contains {
            message.localizedCaseInsensitiveContains($0)
        }
    }

    /// Builds an ADA or native-asset transfer from UTxOs at any of the account's
    /// payment addresses. A token output requires an explicit lovelace amount.
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

        let (utxos, pathsByInput) = try await spendableUTxOs(owner)
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

        var result = try remappingWalletKitError {
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

        result.signingPaths = try CardanoInputPaths.signingPaths(of: result.inputs, pathsByInput: pathsByInput)
        return result
    }

    /// The account's UTxOs it can sign for, keyed to their payment paths.
    /// UTxOs at addresses outside the derivation search are skipped.
    private func spendableUTxOs(
        _ owner: CardanoAccountDescriptor
    ) async throws -> (utxos: [CardanoUtxoFfi], pathsByInput: [String: CardanoSigningPathFfi]) {
        let entries = try await accountUTxOs(owner)
        let paths = try owner.signingPaths(for: Set(entries.map(\.address)))
        var pathsByInput: [String: CardanoSigningPathFfi] = [:]

        let utxos = entries.compactMap { utxo -> CardanoUtxoFfi? in
            guard
                let path = paths[utxo.address],
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

            pathsByInput[CardanoInputPaths.key(txHash: hash, outputIndex: utxo.outputIndex)] = path
            return CardanoUtxoFfi(
                address: utxo.address,
                assets: assets,
                lovelace: lovelace.quantity,
                outputIndex: utxo.outputIndex,
                txHash: hash
            )
        }

        return (utxos, pathsByInput)
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

    public func isActiveAccount(_ owner: CardanoAccountDescriptor) async throws -> Bool {
        !(try await getAllBalances(owner)).isEmpty
    }

    public func isSupported(_ feature: BlockchainClientFeature) -> Bool {
        switch feature {
        case .allBalances, .transactionHistory:
            true
        case .multipleBalances, .transactionSubscription:
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

        /// Blockfrost sends some of these as decimal strings (e.g.
        /// `coins_per_utxo_size`, `key_deposit`) and others as numbers.
        init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            coinsPerUtxoSize = try container.decodeNumericString(forKey: .coinsPerUtxoSize)
            keyDeposit = try container.decodeNumericString(forKey: .keyDeposit)
            maxTxSize = try container.decodeNumericUInt32(forKey: .maxTxSize)
            maxValSize = try container.decodeNumericUInt32(forKey: .maxValSize)
            minFeeA = try container.decodeNumericString(forKey: .minFeeA)
            minFeeB = try container.decodeNumericString(forKey: .minFeeB)
            poolDeposit = try container.decodeNumericString(forKey: .poolDeposit)
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
        try await requestData(.get(url: url, projectId: projectId), path: path)
    }

    private func requestData(_ target: BlockfrostAPI, path: String) async throws -> Data {
        let policy = RateGateRegistry.shared.makeRetryPolicy(for: origin, provider: .blockfrost)
        let afSession = Session(configuration: session.configuration, interceptor: policy)
        let provider = MoyaProvider<BlockfrostAPI>(session: afSession)

        do {
            return try await provider.requestData(target)
        } catch let error as MoyaError {
            if Self.response(of: error)?.statusCode == 404 {
                throw HTTPError.notFound
            }

            throw Self.mapError(error, path: path)
        }
    }

    /// `origin`: scheme + host + explicit port only (not a default one) —
    /// matches ``RateGateRegistry``'s keying.
    private var origin: String {
        var components = URLComponents()
        components.scheme = endpoint.scheme
        components.host = endpoint.host
        components.port = endpoint.port
        return components.string ?? endpoint.absoluteString
    }

    private static func response(of error: MoyaError) -> Moya.Response? {
        switch error {
        case let .statusCode(response): response
        case let .underlying(_, response): response
        default: nil
        }
    }

    /// Includes the response body in the message — not just the status
    /// code — so `broadcast(transaction:signature:)` can recognize an
    /// already-submitted-shaped rejection by its text.
    private static func mapError(_ error: MoyaError, path: String) -> WalletKitError {
        guard let response = Self.response(of: error) else {
            return .internalError(message: "Blockfrost returned an invalid response.")
        }

        let body = String(data: response.data, encoding: .utf8) ?? ""
        return .internalError(message: "Blockfrost rejected \(path): \(body)")
    }
}

private enum HTTPError: Swift.Error, LocalizedError {
    case notFound

    var errorDescription: String? {
        switch self {
        case .notFound: "Not found on the Cardano node."
        }
    }
}

private enum BlockfrostAPI: TargetType {
    case get(url: URL, projectId: String)
    case submit(endpoint: URL, projectId: String, cbor: Data)

    var baseURL: URL {
        switch self {
        case let .get(url, _): url
        case let .submit(endpoint, _, _): endpoint
        }
    }

    var path: String {
        switch self {
        case .get: ""
        case .submit: "tx/submit"
        }
    }

    var method: Moya.Method {
        switch self {
        case .get: .get
        case .submit: .post
        }
    }

    var headers: [String: String]? {
        switch self {
        case let .get(_, projectId):
            ["project_id": projectId]
        case let .submit(_, projectId, _):
            ["Content-Type": "application/cbor", "project_id": projectId]
        }
    }

    var task: Moya.Task {
        switch self {
        case .get: .requestPlain
        case let .submit(_, _, cbor): .requestData(cbor)
        }
    }

    var validationType: ValidationType { .successCodes }

    var sampleData: Data { Data() }
}
