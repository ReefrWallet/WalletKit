import BigInt
import Foundation

/// Minimal HTTP client for Tron FullNode-compatible endpoints.
public struct TronClient: BlockchainClientProtocol, Sendable { // swiftlint:disable:this type_body_length
    public typealias Address = TronAddress

    private let apiKey: String?
    private let endpoint: URL
    private let session: URLSession

    public init(endpoint: URL, apiKey: String? = nil, session: URLSession = .shared) {
        self.endpoint = endpoint
        self.apiKey = apiKey?.trimmingCharacters(in: .whitespacesAndNewlines)
        self.session = session
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

    public func getTokenPrice(_ token: String?) async throws -> Decimal {
        throw WalletKitError.unsupportedFeature
    }

    public func isActiveAccount(_ owner: TronAddress) async throws -> Bool {
        let response = try await post("wallet/getaccount", body: ["address": owner.string, "visible": true])
        return !response.isEmpty
    }

    public func isSupported(_ feature: BlockchainClientFeature) -> Bool {
        switch feature {
        case .feeEstimation, .multipleBalances, .transactionHistory:
            true
        case .allBalances, .transactionSubscription:
            false
        }
    }

    public func estimateFee(for request: FeeEstimateRequest<TronAddress>?) async throws -> FeeEstimate {
        FeeEstimate(gasPrice: 0)
    }

    public func transactionHistory(
        _ owner: TronAddress,
        request: BlockchainTransactionHistoryRequest
    ) async throws -> BlockchainTransactionPage {
        let cursor = request.cursor.flatMap { try? JSONDecoder().decode(HistoryCursor.self, from: $0) }

        async let native = historyResponse(
            path: "v1/accounts/\(owner.string)/transactions",
            request: request,
            fingerprint: cursor?.native
        )

        async let tokens = historyResponse(
            path: "v1/accounts/\(owner.string)/transactions/trc20",
            request: request,
            fingerprint: cursor?.tokens
        )

        let (nativeResponse, tokenResponse) = try await (native, tokens)
        let nativeTransactions = (nativeResponse["data"] as? [[String: Any]] ?? [])
            .compactMap(Self.transaction(from:))
        let tokenTransactions = (tokenResponse["data"] as? [[String: Any]] ?? [])
            .compactMap(Self.tokenTransaction(from:))
        let transactions = Self.merging(nativeTransactions + tokenTransactions)

        let nextCursor = HistoryCursor(
            native: Self.fingerprint(in: nativeResponse),
            tokens: Self.fingerprint(in: tokenResponse)
        )

        let cursorData = try JSONEncoder().encode(nextCursor)

        // `TransactionSyncService` needs `head` to establish `currentHead` and
        // start forward polling — the same role `eth_blockNumber`/
        // `GetServiceInfo.checkpointHeight` play for Ethereum/Sui. Without it,
        // Tron's forward sync stays stalled forever after backfill.
        let head = nativeTransactions.compactMap(\.blockHeight).max()

        return BlockchainTransactionPage(
            transactions: transactions,
            nextCursor: nextCursor.native == nil && nextCursor.tokens == nil ? nil : cursorData,
            reachedBoundary: nextCursor.native == nil && nextCursor.tokens == nil,
            head: head
        )
    }

    public func broadcast(transaction: Data, signature: Data) async throws -> String {
        guard signature.count == 65 else {
            throw WalletKitError.signingFailed(reason: "A Tron signature must be 65 bytes.")
        }

        var payload = try JSONSerialization.jsonObject(with: transaction) as? [String: Any] ?? [:]
        payload["signature"] = [signature.map { String(format: "%02x", $0) }.joined()]

        let response = try await post("wallet/broadcasttransaction", body: payload)

        guard (response["result"] as? Bool) == true,
              let identifier = (response["txid"] as? String) ?? (payload["txID"] as? String) else {
            throw WalletKitError.internalError(message: "Tron node rejected transaction broadcast.")
        }

        return identifier
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
                "amount": amount.description,
                "visible": true
            ])
        }

        guard response["raw_data_hex"] != nil else {
            throw WalletKitError.internalError(message: "Tron node did not construct a transaction.")
        }

        return try JSONSerialization.data(withJSONObject: response)
    }

    private func historyResponse(
        path: String,
        request: BlockchainTransactionHistoryRequest,
        fingerprint: String?
    ) async throws -> [String: Any] {
        var components = URLComponents(url: endpoint.appending(path: path), resolvingAgainstBaseURL: false)

        var items = [
            URLQueryItem(
                name: "only_confirmed",
                value: "true"
            ),
            URLQueryItem(
                name: "limit",
                value: "\(min(request.limit, 200))"
            ),
            URLQueryItem(
                name: "order_by",
                value: request.direction == .ascending ? "block_timestamp,asc" : "block_timestamp,desc"
            )
        ]

        if let fingerprint {
            items.append(URLQueryItem(name: "fingerprint", value: fingerprint))
        }

        components?.queryItems = items

        guard let url = components?.url else {
            throw WalletKitError.internalError(message: "Cannot construct Tron history URL.")
        }

        return try await get(url)
    }

    private func post(_ path: String, body: [String: Any]) async throws -> [String: Any] {
        var request = URLRequest(url: endpoint.appending(path: path))
        request.httpMethod = "POST"
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        if let apiKey, !apiKey.isEmpty {
            request.setValue(apiKey, forHTTPHeaderField: "TRON-PRO-API-KEY")
        }

        let (data, response) = try await session.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse, (200..<300).contains(httpResponse.statusCode) else {
            throw WalletKitError.internalError(message: "Tron endpoint rejected \(path).")
        }

        return try JSONSerialization.jsonObject(with: data) as? [String: Any] ?? [:]
    }

    private func get(_ url: URL) async throws -> [String: Any] {
        var request = URLRequest(url: url)

        if let apiKey, !apiKey.isEmpty {
            request.setValue(apiKey, forHTTPHeaderField: "TRON-PRO-API-KEY")
        }

        let (data, response) = try await session.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse, (200..<300).contains(httpResponse.statusCode) else {
            throw WalletKitError.internalError(message: "TronGrid rejected account-history request.")
        }

        return try JSONSerialization.jsonObject(with: data) as? [String: Any] ?? [:]
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
                blockHeight: first.blockHeight,
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

    private struct HistoryCursor: Codable {
        let native: String?
        let tokens: String?
    }
}
