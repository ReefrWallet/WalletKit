//
//  TonClient.swift
//  WalletKit
//
//  Copyright © 2026 Reefr Wallet. All rights reserved.
//

import BigInt
import Foundation

/// A TON account's lifecycle state.
public enum TonAccountState: Equatable, Sendable {
    case active
    case frozen
    /// No account exists on chain: no balance, never funded.
    case nonexistent
    /// Funded but not deployed: a first send must carry the wallet's `StateInit`.
    case uninitialized
}

/// What a TON message is expected to cost the sender, in nanograms.
public struct TonFeeEstimate: Equatable, Sendable {
    public let forwardFee: BigUInt
    public let gasFee: BigUInt
    public let inboundForwardFee: BigUInt
    public let storageFee: BigUInt

    public var total: BigUInt { forwardFee + gasFee + inboundForwardFee + storageFee }
}

/// TON client over the toncenter HTTP API: v2 for state and submission, v3 for history.
///
/// Gram is the only asset; Jettons arrive in a later milestone, so ``BlockchainClientFeature/allBalances``
/// is unsupported.
public struct TonClient: BlockchainClientProtocol, Sendable {
    public typealias Address = TonAddress

    public let network: TonNetwork
    let transport: any TonTransport

    public init(network: TonNetwork, apiKey: String? = nil, session: URLSession = .shared) {
        let trimmedKey = apiKey?.trimmingCharacters(in: .whitespacesAndNewlines)
        self.init(
            network: network,
            transport: TonCenterTransport(apiKey: trimmedKey?.isEmpty == false ? trimmedKey : nil, session: session)
        )
    }

    init(network: TonNetwork, transport: any TonTransport) {
        self.network = network
        self.transport = transport
    }

    // MARK: BlockchainClientProtocol

    public func makeAddress(_ string: String) throws -> TonAddress {
        let address = try TonAddress(string: string)
        try address.validate(for: network)
        return address
    }

    public func getAllBalances(_ owner: TonAddress) async throws -> [String: BigUInt] {
        throw WalletKitError.unsupportedFeature
    }

    public func getBalances(_ owner: TonAddress, tokens: [String]) async throws -> [String: BigUInt] {
        guard tokens.isEmpty else {
            throw WalletKitError.unsupportedFeature
        }

        return [:]
    }

    public func getBalance(_ owner: TonAddress, token: String) async throws -> BigUInt {
        throw WalletKitError.unsupportedFeature
    }

    public func getNativeBalance(_ owner: TonAddress) async throws -> BigUInt {
        try await accountInformation(owner).balance
    }

    public func getTokenInfo(_ token: String?) async throws -> TokenInfo {
        guard token == nil else {
            throw WalletKitError.unsupportedFeature
        }

        return .gram
    }

    /// Whether the account has ever been active: deployed or frozen. Use ``accountState(_:)`` to tell
    /// an undeployed wallet from an unfunded one.
    public func isActiveAccount(_ owner: TonAddress) async throws -> Bool {
        let state = try await accountState(owner)
        return state == .active || state == .frozen
    }

    public func isSupported(_ feature: BlockchainClientFeature) -> Bool {
        switch feature {
        case .transactionHistory: true
        case .allBalances, .multipleBalances, .transactionSubscription: false
        }
    }

    /// Submits the signed external message for `transaction` (a ``TonUnsignedTransaction`` envelope) and
    /// returns its TEP-467 normalized hash, hex encoded.
    public func broadcast(transaction: Data, signature: Data) async throws -> String {
        let envelope = try JSONDecoder().decode(TonUnsignedTransaction.self, from: transaction)
        return try await send(envelope, signature: signature)
    }

    // MARK: Account

    public func accountState(_ owner: TonAddress) async throws -> TonAccountState {
        try await accountInformation(owner).state
    }

    /// The wallet's next `seqno`; `0` for an account that is not deployed.
    public func seqno(_ owner: TonAddress) async throws -> UInt32 {
        guard try await accountState(owner) == .active else {
            return 0
        }

        let body = try JSONEncoder().encode(RunGetMethodRequest(address: owner.rawString, method: "seqno", stack: []))
        let result: RunGetMethodResult = try await post("runGetMethod", body: body)

        guard result.exitCode == 0, let entry = result.stack.first, entry.count == 2,
              case let .string(kind) = entry[0], kind == "num", case let .string(text) = entry[1],
              let value = UInt32(text.dropFirst(2), radix: 16)
        else {
            throw BlockchainClientError.decodingFailed(reason: "unexpected seqno result")
        }

        return value
    }

    // MARK: Submission

    /// Submits `transaction` signed with `signature`; see ``broadcast(transaction:signature:)``.
    public func send(_ transaction: TonUnsignedTransaction, signature: Data) async throws -> String {
        let boc = try transaction.signedMessage(signature: signature)
        try await postBoc(boc)
        return try transaction.normalizedHash(signature: signature)
    }

    /// Submits an already signed message BoC, for resending a stored request.
    public func postBoc(_ boc: Data) async throws {
        struct Accepted: Decodable {}

        let body = try JSONEncoder().encode(["boc": boc.base64EncodedString()])
        let data = try await transport.submit(network.rpcURL.appending(path: "sendBoc"), body: body)
        let _: Accepted = try Self.unwrap(data)
    }

    /// The expected fee of `transaction`, estimated on the actual message including a `StateInit` when the
    /// wallet is being deployed.
    public func estimateFee(_ transaction: TonUnsignedTransaction) async throws -> TonFeeEstimate {
        let wallet = try TonAddress(string: transaction.sender)
        let signedBody = try TonBOC.parse(transaction.body).appending(Data(repeating: 0, count: 64))

        var request = EstimateFeeRequest(
            address: wallet.rawString,
            body: TonBOC.serialize(signedBody).base64EncodedString(),
            ignoreChksig: true
        )

        if let stateInit = try transaction.stateInit.map(TonBOC.parse) {
            request.initCode = TonBOC.serialize(stateInit.refs[0]).base64EncodedString()
            request.initData = TonBOC.serialize(stateInit.refs[1]).base64EncodedString()
        }

        let result: EstimateFeeResult = try await post("estimateFee", body: JSONEncoder().encode(request))
        return TonFeeEstimate(
            forwardFee: BigUInt(result.sourceFees.forwardFee),
            gasFee: BigUInt(result.sourceFees.gasFee),
            inboundForwardFee: BigUInt(result.sourceFees.inboundForwardFee),
            storageFee: BigUInt(result.sourceFees.storageFee)
        )
    }
}

// MARK: - toncenter v2

extension TonClient {
    struct AccountInformation {
        let balance: BigUInt
        /// The logical time of the account's latest transaction; `nil` if it has none.
        var lastTransactionLt: UInt64?
        let state: TonAccountState
    }

    struct Envelope<Result: Decodable>: Decodable {
        let ok: Bool
        let result: Result?
        let error: String?
        let code: Int?
    }

    struct EstimateFeeRequest: Encodable {
        let address: String
        let body: String
        let ignoreChksig: Bool
        var initCode: String?
        var initData: String?

        enum CodingKeys: String, CodingKey {
            case address, body
            case ignoreChksig = "ignore_chksig"
            case initCode = "init_code"
            case initData = "init_data"
        }
    }

    struct EstimateFeeResult: Decodable {
        struct Fees: Decodable {
            let forwardFee: UInt64
            let gasFee: UInt64
            let inboundForwardFee: UInt64
            let storageFee: UInt64

            enum CodingKeys: String, CodingKey {
                case forwardFee = "fwd_fee"
                case gasFee = "gas_fee"
                case inboundForwardFee = "in_fwd_fee"
                case storageFee = "storage_fee"
            }
        }

        let sourceFees: Fees

        enum CodingKeys: String, CodingKey {
            case sourceFees = "source_fees"
        }
    }

    struct RunGetMethodRequest: Encodable {
        let address: String
        let method: String
        let stack: [[String]]
    }

    struct RunGetMethodResult: Decodable {
        let exitCode: Int
        let stack: [[JSONScalar]]

        enum CodingKeys: String, CodingKey {
            case exitCode = "exit_code"
            case stack
        }
    }

    /// A stack entry component: a type tag or a value.
    enum JSONScalar: Decodable {
        case other
        case string(String)

        init(from decoder: any Decoder) throws {
            if let text = try? decoder.singleValueContainer().decode(String.self) {
                self = .string(text)
            } else {
                self = .other
            }
        }
    }

    func accountInformation(_ owner: TonAddress) async throws -> AccountInformation {
        struct Result: Decodable {
            struct TransactionId: Decodable {
                let lt: String
            }

            let balance: String
            let lastTransactionId: TransactionId?
            let state: String

            enum CodingKeys: String, CodingKey {
                case balance
                case lastTransactionId = "last_transaction_id"
                case state
            }
        }

        let result: Result = try await get("getAddressInformation", query: ["address": owner.rawString])

        guard let balance = BigUInt(result.balance) else {
            throw BlockchainClientError.decodingFailed(reason: "invalid TON balance \(result.balance)")
        }

        let lt = result.lastTransactionId.flatMap { UInt64($0.lt) }.flatMap { $0 == 0 ? nil : $0 }

        switch result.state {
        case "active": return AccountInformation(balance: balance, lastTransactionLt: lt, state: .active)
        case "frozen": return AccountInformation(balance: balance, lastTransactionLt: lt, state: .frozen)
        case "uninitialized":
            return AccountInformation(
                balance: balance,
                lastTransactionLt: lt,
                state: balance == 0 ? .nonexistent : .uninitialized
            )

        default: throw BlockchainClientError.decodingFailed(reason: "unknown TON account state \(result.state)")
        }
    }

    func get<Result: Decodable>(_ method: String, query: [String: String]) async throws -> Result {
        var components = URLComponents(url: network.rpcURL.appending(path: method), resolvingAgainstBaseURL: false)
        components?.queryItems = query.sorted { $0.key < $1.key }.map { URLQueryItem(name: $0.key, value: $0.value) }

        guard let url = components?.url else {
            throw BlockchainClientError.invalidResponse(reason: "invalid toncenter URL")
        }

        return try Self.unwrap(try await transport.get(url))
    }

    func post<Result: Decodable>(_ method: String, body: Data) async throws -> Result {
        try Self.unwrap(try await postData(method, body: body))
    }

    func postData(_ method: String, body: Data) async throws -> Data {
        try await transport.post(network.rpcURL.appending(path: method), body: body)
    }

    private static func unwrap<Result: Decodable>(_ data: Data) throws -> Result {
        let envelope: Envelope<Result>

        do {
            envelope = try JSONDecoder().decode(Envelope<Result>.self, from: data)
        } catch {
            throw BlockchainClientError.decodingFailed(reason: "toncenter: \(error)")
        }

        guard envelope.ok, let result = envelope.result else {
            let code = envelope.code ?? 0
            let message = envelope.error ?? "unknown error"

            if code == 429 {
                throw BlockchainClientError.quotaExceeded(code: code, message: message, retryAfter: nil)
            }

            throw BlockchainClientError.rpcError(code: code, message: message)
        }

        return result
    }
}
