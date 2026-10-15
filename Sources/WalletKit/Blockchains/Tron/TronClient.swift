import Alamofire
import BigInt
import Foundation
import Moya

/// Minimal HTTP client for Tron FullNode-compatible endpoints.
///
/// Rate-limit handling (retrying 429/503 with backoff; no proactive pacing
/// until TronGrid's real plan/key-tier limit is confirmed — see
/// ``RateGateRegistry``) comes from the shared registry, looked up by this
/// client's own endpoint.
public struct TronClient: BlockchainClientProtocol, Sendable { // swiftlint:disable:this type_body_length
    public typealias Address = TronAddress

    private static let internalTransactionsPageSize = 50

    private let apiKey: String?
    private let endpoint: URL
    private let session: URLSession
    private let tronScanAPIKey: String?
    private let tronScanEndpoint: URL?

    /// - Parameter tronScanEndpoint: TronScan API used for internal TRX transfers
    ///   (e.g. swap/relayer payouts), which TronGrid's account history omits.
    public init(
        endpoint: URL,
        apiKey: String? = nil,
        tronScanEndpoint: URL? = nil,
        tronScanAPIKey: String? = nil,
        session: URLSession = .shared
    ) {
        self.endpoint = endpoint
        self.apiKey = apiKey?.trimmingCharacters(in: .whitespacesAndNewlines)
        self.session = session
        self.tronScanAPIKey = tronScanAPIKey?.trimmingCharacters(in: .whitespacesAndNewlines)
        self.tronScanEndpoint = tronScanEndpoint
    }

    public func getAllBalances(_ owner: TronAddress) async throws -> [String: BigUInt] {
        throw WalletKitError.unsupportedFeature
    }

    public func getBalance(_ owner: TronAddress, token: String) async throws -> BigUInt {
        let contract = try TronAddress(string: token)
        let paddedOwner = owner.rawBytes.dropFirst().map { String(format: "%02x", $0) }.joined()
        let parameter = String(repeating: "0", count: 24) + paddedOwner

        let result = try await constantCall(
            owner: owner,
            contract: contract,
            selector: "balanceOf(address)",
            parameter: parameter
        )

        guard let amount = BigUInt(result, radix: 16) else {
            throw WalletKitError.internalError(message: "Tron node returned an invalid TRC-20 balance.")
        }

        return amount
    }

    public func getBalances(_ owner: TronAddress, tokens: [String]) async throws -> [String: BigUInt] {
        var balances: [String: BigUInt] = [:]

        for token in tokens {
            balances[token] = try await getBalance(owner, token: token)
        }

        return balances
    }

    public func getNativeBalance(_ owner: TronAddress) async throws -> BigUInt {
        let response = try await post("wallet/getaccount", body: ["address": owner.string, "visible": true])

        guard let balance = response["balance"] as? NSNumber else {
            return 0
        }

        return BigUInt(balance.uint64Value)
    }

    public func getTokenInfo(_ token: String?) async throws -> TokenInfo {
        guard let token else {
            return .tron
        }

        let address = try TronAddress(string: token)

        async let decimals = constantCall(owner: address, contract: address, selector: "decimals()")
        async let name = constantCall(owner: address, contract: address, selector: "name()")
        async let symbol = constantCall(owner: address, contract: address, selector: "symbol()")

        let (decimalsValue, nameValue, symbolValue) = try await (decimals, name, symbol)

        guard let decimalCount = UInt8(decimalsValue, radix: 16) else {
            throw WalletKitError.internalError(message: "Invalid TRC-20 decimal count.")
        }

        return TokenInfo(
            decimals: decimalCount,
            name: decodeABIString(nameValue),
            isNative: false,
            symbol: decodeABIString(symbolValue)
        )
    }

    public func isActiveAccount(_ owner: TronAddress) async throws -> Bool {
        let response = try await post("wallet/getaccount", body: ["address": owner.string, "visible": true])
        return !response.isEmpty
    }

    public func isSupported(_ feature: BlockchainClientFeature) -> Bool {
        switch feature {
        case .multipleBalances, .transactionHistory:
            true
        case .allBalances, .transactionSubscription:
            false
        }
    }

    public func transactionHistory(
        _ owner: TronAddress,
        request: BlockchainTransactionHistoryRequest
    ) async throws -> BlockchainTransactionPage {
        var cursor = try await historyCursor(for: request)

        // Block-height bounds map to timestamps, the only range filter the indexers take.
        // `head` is the solidified tip (or `upperBound`), so it's known even for accounts
        // with no native transactions; without it forward sync never starts.
        if let minTimestamp = cursor.minTimestamp, minTimestamp > cursor.maxTimestamp {
            return BlockchainTransactionPage(
                transactions: [],
                nextCursor: nil,
                reachedBoundary: true,
                head: cursor.head
            )
        }

        let start = cursor

        async let native = historyPage(
            path: "v1/accounts/\(owner.string)/transactions",
            request: request,
            cursor: start,
            position: start.native
        )

        async let tokens = historyPage(
            path: "v1/accounts/\(owner.string)/transactions/trc20",
            request: request,
            cursor: start,
            position: start.tokens
        )

        async let internals = internalTransactionsPage(owner, cursor: start)

        let (nativePage, tokenPage, internalPage) = try await (native, tokens, internals)
        cursor.native = nativePage.next
        cursor.tokens = tokenPage.next
        cursor.internals = internalPage.next

        let transactions = try await withBlockHeights(
            Self.merging(
                nativePage.data.compactMap(Self.transaction(from:))
                    + internalPage.data.compactMap { Self.internalTransaction(from: $0, owner: owner.string) }
                    + tokenPage.data.compactMap(Self.tokenTransaction(from:))
            )
        )

        return BlockchainTransactionPage(
            transactions: transactions,
            nextCursor: cursor.isExhausted ? nil : try JSONEncoder().encode(cursor),
            reachedBoundary: cursor.isExhausted,
            head: cursor.head
        )
    }

    public func broadcast(transaction: Data, signature: Data) async throws -> String {
        guard signature.count == 65 else {
            throw WalletKitError.signingFailed(reason: "A Tron signature must be 65 bytes.")
        }

        var payload = try JSONSerialization.jsonObject(with: transaction) as? [String: Any] ?? [:]
        payload["signature"] = [signature.map { String(format: "%02x", $0) }.joined()]

        // Already known before broadcasting — the unsigned payload's own
        // txID (`raw_data_hex`'s hash), not just a fallback for when the
        // response omits it.
        let knownTxId = payload["txID"] as? String

        let response = try await post("wallet/broadcasttransaction", body: payload)

        if (response["result"] as? Bool) == true {
            guard let identifier = (response["txid"] as? String) ?? knownTxId else {
                throw WalletKitError.internalError(message: "Tron node rejected transaction broadcast.")
            }

            return identifier
        }

        // A 429/503 retry can land on this after the first attempt
        // actually landed — "DUP_TRANSACTION_ERROR" is java-tron's reject
        // reason for a transaction it's already seen. The txID is already
        // known from the unsigned payload (this is the same identifier
        // java-tron itself derived when it first built the transaction,
        // not a value we're trusting from this second, failing response),
        // so recover it instead of surfacing a false failure.
        if Self.looksLikeDuplicate(response), let knownTxId {
            return knownTxId
        }

        throw WalletKitError.internalError(message: "Tron node rejected transaction broadcast: \(Self.rejectionReason(response))")
    }

    /// java-tron's `code` plus its hex-encoded ASCII `message`.
    private static func rejectionReason(_ response: [String: Any]) -> String {
        let code = response["code"] as? String
        let message = (response["message"] as? String)
            .flatMap { try? Data(hexString: $0) }
            .flatMap { String(data: $0, encoding: .utf8) }

        return [code, message].compactMap { $0 }.joined(separator: ": ")
    }

    private static func looksLikeDuplicate(_ response: [String: Any]) -> Bool {
        if let code = response["code"] as? String, code.localizedCaseInsensitiveContains("dup") {
            return true
        }

        // java-tron error messages are hex-encoded ASCII.
        if let messageHex = response["message"] as? String,
           let data = try? Data(hexString: messageHex),
           let text = String(data: data, encoding: .utf8) {
            return text.localizedCaseInsensitiveContains("dup")
        }

        return false
    }

    func buildTransfer(
        sender: TronAddress,
        recipient: TronAddress,
        amount: BigUInt,
        token: String?,
        feeLimit: UInt64?
    ) async throws -> Data {
        let response: [String: Any]

        if let token {
            let contract = try TronAddress(string: token)
            let recipientParameter = recipient.rawBytes.dropFirst().map { String(format: "%02x", $0) }.joined()
            let amountParameter = String(amount, radix: 16).leftPadding(to: 64)
            response = try await post("wallet/triggersmartcontract", body: [
                "contract_address": contract.string,
                "function_selector": "transfer(address,uint256)",
                "owner_address": sender.string,
                "parameter": String(repeating: "0", count: 24) + recipientParameter + amountParameter,
                "fee_limit": feeLimit ?? 100_000_000,
                "visible": true
            ])
        } else {
            guard amount <= BigUInt(UInt64.max) else {
                throw BlockchainTransactionBuilderError.amountTooLarge
            }

            response = try await post("wallet/createtransaction", body: [
                "owner_address": sender.string,
                "to_address": recipient.string,
                "amount": UInt64(amount),
                "visible": true
            ])
        }

        // `triggersmartcontract` nests the transaction under `transaction`.
        let transaction = (response["transaction"] as? [String: Any]) ?? response

        guard transaction["raw_data_hex"] != nil else {
            let reason = (response["Error"] as? String) ?? Self.rejectionReason(response)
            throw WalletKitError.internalError(message: "Tron node did not construct a transaction: \(reason)")
        }

        return try JSONSerialization.data(withJSONObject: transaction)
    }

    private func block(number: UInt64?) async throws -> BlockStamp {
        var body: [String: Any] = ["detail": false]
        body["id_or_num"] = number.map(String.init)
        let header = (try await post("walletsolidity/getblock", body: body)["block_header"] as? [String: Any])
        let rawData = header?["raw_data"] as? [String: Any]

        guard let timestamp = (rawData?["timestamp"] as? NSNumber)?.uint64Value else {
            throw WalletKitError.internalError(message: "Tron node returned no solidified block.")
        }

        // Protobuf JSON omits zero values, so genesis has no `number`.
        return BlockStamp(number: (rawData?["number"] as? NSNumber)?.uint64Value ?? 0, timestamp: timestamp)
    }

    private func historyCursor(for request: BlockchainTransactionHistoryRequest) async throws -> HistoryCursor {
        if let data = request.cursor, let cursor = try? JSONDecoder().decode(HistoryCursor.self, from: data) {
            return cursor
        }

        let head = try await block(number: request.upperBound)
        var minTimestamp: UInt64?

        if let lowerBound = request.lowerBound, lowerBound > 0 {
            minTimestamp = lowerBound > head.number
                ? head.timestamp + 1
                : try await block(number: lowerBound - 1).timestamp + 1
        }

        return HistoryCursor(head: head.number, maxTimestamp: head.timestamp, minTimestamp: minTimestamp)
    }

    private func historyPage(
        path: String,
        request: BlockchainTransactionHistoryRequest,
        cursor: HistoryCursor,
        position: StreamPosition
    ) async throws -> HistoryPage {
        if position == .done {
            return HistoryPage(data: [], next: .done)
        }

        var components = URLComponents(url: endpoint.appending(path: path), resolvingAgainstBaseURL: false)

        var items = [
            URLQueryItem(name: "only_confirmed", value: "true"),
            URLQueryItem(name: "limit", value: "\(min(request.limit, 200))"),
            URLQueryItem(
                name: "order_by",
                value: request.direction == .ascending ? "block_timestamp,asc" : "block_timestamp,desc"
            ),
            URLQueryItem(name: "max_timestamp", value: "\(cursor.maxTimestamp)")
        ]

        if let minTimestamp = cursor.minTimestamp {
            items.append(URLQueryItem(name: "min_timestamp", value: "\(minTimestamp)"))
        }

        if case let .fingerprint(fingerprint) = position {
            items.append(URLQueryItem(name: "fingerprint", value: fingerprint))
        }

        components?.queryItems = items

        guard let url = components?.url else {
            throw WalletKitError.internalError(message: "Cannot construct Tron history URL.")
        }

        let response = try await get(url, apiKey: apiKey)

        return HistoryPage(
            data: response["data"] as? [[String: Any]] ?? [],
            next: Self.fingerprint(in: response).map(StreamPosition.fingerprint) ?? .done
        )
    }

    private func internalTransactionsPage(_ owner: TronAddress, cursor: HistoryCursor) async throws -> HistoryPage {
        guard let tronScanEndpoint, cursor.internals != .done else {
            return HistoryPage(data: [], next: .done)
        }

        let offset = if case let .offset(offset) = cursor.internals { offset } else { 0 }
        let pageSize = Self.internalTransactionsPageSize
        var components = URLComponents(
            url: tronScanEndpoint.appending(path: "api/internal-transaction"),
            resolvingAgainstBaseURL: false
        )

        var items = [
            URLQueryItem(name: "address", value: owner.string),
            URLQueryItem(name: "start", value: "\(offset)"),
            URLQueryItem(name: "limit", value: "\(pageSize)"),
            URLQueryItem(name: "end_timestamp", value: "\(cursor.maxTimestamp)")
        ]

        if let minTimestamp = cursor.minTimestamp {
            items.append(URLQueryItem(name: "start_timestamp", value: "\(minTimestamp)"))
        }

        components?.queryItems = items

        guard let url = components?.url else {
            throw WalletKitError.internalError(message: "Cannot construct TronScan URL.")
        }

        let data = try await get(url, apiKey: tronScanAPIKey)["data"] as? [[String: Any]] ?? []

        return HistoryPage(data: data, next: data.count < pageSize ? .done : .offset(offset + data.count))
    }

    /// TronGrid's TRC-20 history has no block numbers; without one a transaction reads as pending.
    private func withBlockHeights(_ transactions: [BlockchainTransaction]) async throws -> [BlockchainTransaction] {
        try await withThrowingTaskGroup(of: (Int, UInt64?).self) { group in
            for (index, transaction) in transactions.enumerated() where transaction.blockHeight == nil {
                group.addTask {
                    let info = try await post(
                        "walletsolidity/gettransactioninfobyid",
                        body: ["value": transaction.identifier]
                    )

                    return (index, (info["blockNumber"] as? NSNumber)?.uint64Value)
                }
            }

            var transactions = transactions

            for try await (index, blockHeight) in group {
                transactions[index] = transactions[index].with(blockHeight: blockHeight)
            }

            return transactions
        }
    }

    /// Forwards one node HTTP request (e.g. TronWeb's `wallet/getaccount`)
    /// to this endpoint with this client's API key and rate-limit
    /// handling, returning the raw response body. The caller decides
    /// which paths are allowed.
    ///
    /// - Parameters:
    ///   - path: A relative path such as `wallet/triggerconstantcontract`.
    ///   - query: Query items for a GET request.
    ///   - body: The JSON body for a POST request; `nil` sends a GET.
    public func relay(path: String, query: [URLQueryItem] = [], body: Data?) async throws -> Data {
        let target: TronGridAPI
        if let body {
            target = .post(endpoint: endpoint, path: path, apiKey: apiKey, body: body)
        } else {
            var components = URLComponents(
                url: endpoint.appendingPathComponent(path),
                resolvingAgainstBaseURL: false
            )

            components?.queryItems = query.isEmpty ? nil : query

            guard let url = components?.url else {
                throw WalletKitError.internalError(message: "Invalid Tron relay path.")
            }

            target = .get(url: url, apiKey: apiKey)
        }

        let policy = RateGateRegistry.shared.makeRetryPolicy(for: origin, provider: .tronGrid)
        let afSession = Session(configuration: session.configuration, interceptor: policy)
        let provider = MoyaProvider<TronGridAPI>(session: afSession)

        do {
            return try await provider.requestData(target)
        } catch let error as MoyaError {
            throw Self.requestFailed("Tron request \(path)", error)
        }
    }

    private func post(_ path: String, body: [String: Any]) async throws -> [String: Any] {
        let bodyData = try JSONSerialization.data(withJSONObject: body)
        return try await requestJSONObject(
            .post(endpoint: endpoint, path: path, apiKey: apiKey, body: bodyData),
            context: "Tron request \(path)"
        )
    }

    private func get(_ url: URL, apiKey: String?) async throws -> [String: Any] {
        try await requestJSONObject(
            .get(url: url, apiKey: apiKey),
            context: "\(url.host ?? "Tron indexer") account-history request"
        )
    }

    private func requestJSONObject(_ target: TronGridAPI, context: String) async throws -> [String: Any] {
        // TronScan requests get their own rate gate.
        let origin = Self.origin(of: target.baseURL)
        let policy = RateGateRegistry.shared.makeRetryPolicy(for: origin, provider: .tronGrid)
        let afSession = Session(configuration: session.configuration, interceptor: policy)
        let provider = MoyaProvider<TronGridAPI>(session: afSession)

        do {
            return try await provider.requestJSONObject(target)
        } catch MoyaError.jsonMapping {
            // Matches the original `try? ... ?? [:]` tolerance: a 2xx
            // response whose body isn't a JSON object yields an empty
            // dictionary rather than a thrown error.
            return [:]
        } catch let error as MoyaError {
            throw Self.requestFailed(context, error)
        }
    }

    /// Wraps a failed request with what actually went wrong — the HTTP
    /// status plus the start of the body (where TronGrid puts its reason),
    /// or the transport error (timeout, offline, cancellation, ...) — so
    /// those don't all collapse into one generic "rejected" message.
    private static func requestFailed(_ context: String, _ error: MoyaError) -> WalletKitError {
        let detail: String = switch error {
        case let .statusCode(response),
             let .underlying(_, response?):
            describe(response)
        case let .underlying(underlying, nil):
            underlying.localizedDescription
        default:
            error.localizedDescription
        }

        return .internalError(message: "\(context) failed: \(detail)")
    }

    private static func describe(_ response: Response) -> String {
        let body = (String(bytes: response.data.prefix(200), encoding: .utf8) ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        return body.isEmpty ? "HTTP \(response.statusCode)" : "HTTP \(response.statusCode): \(body)"
    }

    /// `origin`: scheme + host + explicit port only (not a default one) —
    /// matches ``RateGateRegistry``'s keying.
    private var origin: String {
        Self.origin(of: endpoint)
    }

    private static func origin(of url: URL) -> String {
        var components = URLComponents()
        components.scheme = url.scheme
        components.host = url.host
        components.port = url.port
        return components.string ?? url.absoluteString
    }

    private func constantCall(
        owner: TronAddress,
        contract: TronAddress,
        selector: String,
        parameter: String? = nil
    ) async throws -> String {
        var body: [String: Any] = [
            "contract_address": contract.string,
            "function_selector": selector,
            "owner_address": owner.string,
            "visible": true
        ]

        if let parameter {
            body["parameter"] = parameter
        }

        let response = try await post("wallet/triggerconstantcontract", body: body)

        guard let results = response["constant_result"] as? [String], let result = results.first else {
            throw WalletKitError.internalError(message: "Tron node returned no contract-call result.")
        }

        return result
    }

    private func decodeABIString(_ value: String) -> String {
        guard let data = try? Data(hexString: value), !data.isEmpty else {
            return ""
        }

        if data.count == 32 {
            return String(data: data.prefix(while: { $0 != 0 }), encoding: .utf8) ?? ""
        }

        guard data.count >= 64 else {
            return ""
        }

        let offset = Int(data.prefix(32).reduce(0) { ($0 << 8) + Int($1) })

        guard offset + 32 <= data.count else {
            return ""
        }

        let length = Int(data[offset..<(offset + 32)].reduce(0) { ($0 << 8) + Int($1) })

        guard offset + 32 + length <= data.count else {
            return ""
        }

        return String(data: data[(offset + 32)..<(offset + 32 + length)], encoding: .utf8) ?? ""
    }

    private static func transaction(from value: [String: Any]) -> BlockchainTransaction? {
        guard let identifier = value["txID"] as? String else {
            return nil
        }

        let blockHeight = (value["blockNumber"] as? NSNumber)?.uint64Value
        let timestamp = (value["block_timestamp"] as? NSNumber)
            .map { Date(timeIntervalSince1970: $0.doubleValue / 1_000) }

        let contracts = ((value["raw_data"] as? [String: Any])?["contract"] as? [[String: Any]]) ?? []
        let transfer = contracts.first(where: { ($0["type"] as? String) == "TransferContract" })
        let payload = ((transfer?["parameter"] as? [String: Any])?["value"] as? [String: Any])
        let amount = (payload?["amount"] as? NSNumber)?.stringValue
        let sender = payload?["owner_address"] as? String
        let recipient = payload?["to_address"] as? String

        let effects = amount.map {
            [BlockchainTransactionEffect(index: 0, kind: .nativeTransfer, amount: $0, from: sender, to: recipient)]
        } ?? []

        return BlockchainTransaction(
            identifier: identifier,
            blockHeight: blockHeight,
            timestamp: timestamp,
            sender: sender,
            recipient: recipient,
            status: .confirmed,
            effects: effects
        )
    }

    private static func tokenTransaction(from value: [String: Any]) -> BlockchainTransaction? {
        guard let identifier = value["transaction_id"] as? String,
              let tokenInfo = value["token_info"] as? [String: Any],
              let tokenAddress = tokenInfo["address"] as? String,
              let amount = value["value"] as? String else {
            return nil
        }

        let timestamp = (value["block_timestamp"] as? NSNumber)
            .map { Date(timeIntervalSince1970: $0.doubleValue / 1_000) }

        let sender = value["from"] as? String
        let recipient = value["to"] as? String

        return BlockchainTransaction(
            identifier: identifier,
            timestamp: timestamp,
            sender: sender,
            recipient: recipient,
            status: .confirmed,
            effects: [
                BlockchainTransactionEffect(
                    index: 0,
                    kind: .tokenTransfer,
                    assetIdentifier: tokenAddress,
                    amount: amount,
                    from: sender,
                    to: recipient
                )
            ]
        )
    }

    /// A TronScan internal TRX transfer, e.g. a swap router paying out to `owner`.
    private static func internalTransaction(from value: [String: Any], owner: String) -> BlockchainTransaction? {
        guard let identifier = value["hash"] as? String,
              let sender = value["from"] as? String,
              let recipient = value["to"] as? String,
              sender == owner || recipient == owner,
              (value["token_id"] as? String ?? "_") == "_",
              let amount = (value["call_value"] as? NSNumber)?.uint64Value, amount > 0,
              value["confirmed"] as? Bool != false,
              value["rejected"] as? Bool != true,
              value["revert"] as? Bool != true else {
            return nil
        }

        let timestamp = (value["timestamp"] as? NSNumber)
            .map { Date(timeIntervalSince1970: $0.doubleValue / 1_000) }

        return BlockchainTransaction(
            identifier: identifier,
            blockHeight: (value["block"] as? NSNumber)?.uint64Value,
            timestamp: timestamp,
            sender: sender,
            recipient: recipient,
            status: .confirmed,
            effects: [
                BlockchainTransactionEffect(
                    index: 0,
                    kind: .nativeTransfer,
                    amount: String(amount),
                    from: sender,
                    to: recipient
                )
            ]
        )
    }

    private static func fingerprint(in response: [String: Any]) -> String? {
        (response["meta"] as? [String: Any])?["fingerprint"] as? String
    }

    private static func merging(_ transactions: [BlockchainTransaction]) -> [BlockchainTransaction] {
        var groups: [String: [BlockchainTransaction]] = [:]
        var identifiers: [String] = []

        for transaction in transactions {
            if groups[transaction.identifier] == nil {
                identifiers.append(transaction.identifier)
            }

            groups[transaction.identifier, default: []].append(transaction)
        }

        return identifiers.compactMap { identifier in
            guard let group = groups[identifier] else {
                return nil
            }

            let first = group[0]

            let effects = group.flatMap(\.effects).enumerated().map { index, effect in
                BlockchainTransactionEffect(
                    index: UInt64(index),
                    kind: effect.kind,
                    assetIdentifier: effect.assetIdentifier,
                    amount: effect.amount,
                    from: effect.from,
                    to: effect.to,
                    rawPayload: effect.rawPayload
                )
            }

            return BlockchainTransaction(
                identifier: first.identifier,
                blockHeight: group.lazy.compactMap(\.blockHeight).first,
                blockHash: first.blockHash,
                timestamp: first.timestamp,
                transactionIndex: first.transactionIndex,
                sender: first.sender,
                recipient: first.recipient,
                status: first.status,
                rawPayload: first.rawPayload,
                effects: effects
            )
        }
    }

    private struct BlockStamp {
        let number: UInt64
        let timestamp: UInt64
    }

    /// One history range, `(minTimestamp, maxTimestamp]`, paged per stream.
    private struct HistoryCursor: Codable {
        let head: UInt64
        let maxTimestamp: UInt64
        let minTimestamp: UInt64?
        var internals = StreamPosition.start
        var native = StreamPosition.start
        var tokens = StreamPosition.start

        var isExhausted: Bool {
            internals == .done && native == .done && tokens == .done
        }
    }

    private struct HistoryPage {
        let data: [[String: Any]]
        let next: StreamPosition
    }

    private enum StreamPosition: Codable, Equatable {
        case done
        case fingerprint(String)
        case offset(Int)
        case start
    }
}

private extension BlockchainTransaction {
    func with(blockHeight: UInt64?) -> BlockchainTransaction {
        BlockchainTransaction(
            identifier: identifier,
            blockHeight: blockHeight ?? self.blockHeight,
            blockHash: blockHash,
            timestamp: timestamp,
            transactionIndex: transactionIndex,
            sender: sender,
            recipient: recipient,
            status: status,
            rawPayload: rawPayload,
            effects: effects
        )
    }
}

private enum TronGridAPI: TargetType {
    case get(url: URL, apiKey: String?)
    case post(endpoint: URL, path: String, apiKey: String?, body: Data)

    var baseURL: URL {
        switch self {
        case let .get(url, _): url
        case let .post(endpoint, _, _, _): endpoint
        }
    }

    var path: String {
        switch self {
        case .get: ""
        case let .post(_, path, _, _): path
        }
    }

    var method: Moya.Method {
        switch self {
        case .get: .get
        case .post: .post
        }
    }

    var headers: [String: String]? {
        let apiKey: String?

        switch self {
        case let .get(_, key), let .post(_, _, key, _):
            apiKey = key
        }

        guard let apiKey, !apiKey.isEmpty else {
            return method == .post ? ["Content-Type": "application/json"] : nil
        }

        var headers = ["TRON-PRO-API-KEY": apiKey]

        if method == .post {
            headers["Content-Type"] = "application/json"
        }

        return headers
    }

    var task: Moya.Task {
        switch self {
        case .get: .requestPlain
        case let .post(_, _, _, body): .requestData(body)
        }
    }

    var validationType: ValidationType { .successCodes }

    var sampleData: Data { Data() }
} // swiftlint:disable:this file_length
