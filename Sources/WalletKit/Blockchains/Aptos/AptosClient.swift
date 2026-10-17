//
//  AptosClient.swift
//  WalletKit
//
//  Copyright © 2026 Reefr Wallet. All rights reserved.
//

import Alamofire
import BigInt
import Foundation
import Moya
import WalletKitRust

/// Aptos client over the full-node REST API and the indexer GraphQL API.
///
/// The node serves account state, simulation, and submission. The indexer
/// serves bulk balances, token metadata, and account history (the node only
/// lists transactions an account sent). Both accept the same optional Aptos
/// Labs API key as a bearer token.
public struct AptosClient: BlockchainClientProtocol, Sendable {
    public typealias Address = AptosAddress

    /// The Coin-standard type of APT. Its paired Fungible Asset is `0xa`.
    public static let nativeCoinType = "0x1::aptos_coin::AptosCoin"

    static let callTimeout: TimeInterval = 10

    let endpoint: URL
    let indexerURL: URL?
    let apiKey: String?
    let session: URLSession

    public init(endpoint: URL, indexerURL: URL?, apiKey: String?, session: URLSession = .shared) {
        self.endpoint = endpoint
        self.indexerURL = indexerURL
        let trimmedKey = apiKey?.trimmingCharacters(in: .whitespacesAndNewlines)
        self.apiKey = trimmedKey?.isEmpty == false ? trimmedKey : nil
        self.session = session
    }

    /// The `0x`-prefixed hash a node reports for BCS `SignedTransaction` bytes
    /// (a raw transaction followed by its authenticator).
    public static func transactionHash(of signedTransaction: Data) -> String {
        aptosTransactionHash(signedTransaction: signedTransaction).hexEncoded
    }

    /// `true` for either form of APT: its coin type or its `0xa` Fungible
    /// Asset metadata address (any zero padding).
    public static func isNativeAsset(_ assetType: String) -> Bool {
        if assetType == nativeCoinType {
            return true
        }

        guard let address = try? AptosAddress(chainString: assetType) else {
            return false
        }

        return address.string == "0xa"
    }

    /// The canonical identifier for `assetType`: ``nativeCoinType`` for APT,
    /// otherwise the coin type as given or a long-form metadata address.
    static func canonicalAssetType(_ assetType: String) -> String {
        if isNativeAsset(assetType) {
            return nativeCoinType
        }

        if !assetType.contains("::"), let address = try? AptosAddress(chainString: assetType) {
            return address.longString
        }

        return assetType
    }
}

// MARK: - Node REST

public struct AptosLedgerInfo: Decodable, Sendable {
    public let chainId: UInt8
    public let ledgerVersion: UInt64
    /// Microseconds since the Unix epoch.
    public let ledgerTimestamp: UInt64

    enum CodingKeys: String, CodingKey {
        case chainId = "chain_id"
        case ledgerTimestamp = "ledger_timestamp"
        case ledgerVersion = "ledger_version"
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        chainId = try container.decode(UInt8.self, forKey: .chainId)
        ledgerVersion = try container.decodeNumericString(forKey: .ledgerVersion)
        ledgerTimestamp = try container.decodeNumericString(forKey: .ledgerTimestamp)
    }
}

/// `GET /estimate_gas_price`, in octas per gas unit.
public struct AptosGasPriceEstimate: Decodable, Sendable {
    public let deprioritized: UInt64?
    public let estimate: UInt64
    public let prioritized: UInt64?

    enum CodingKeys: String, CodingKey {
        case deprioritized = "deprioritized_gas_estimate"
        case estimate = "gas_estimate"
        case prioritized = "prioritized_gas_estimate"
    }
}

/// The outcome of `/transactions/simulate`.
public struct AptosSimulation: Sendable {
    public let gasUnitPrice: UInt64
    public let gasUsed: UInt64
    public let success: Bool
    public let vmStatus: String

    /// `gasUsed × gasUnitPrice`, in octas.
    public var fee: UInt64 {
        let (fee, overflow) = gasUsed.multipliedReportingOverflow(by: gasUnitPrice)
        return overflow ? .max : fee
    }
}

/// A committed (or still pending) transaction as the node reports it.
public struct AptosTransactionStatus: Sendable {
    /// `address::module::function` of an entry-function payload.
    public let entryFunction: String?
    public let gasUnitPrice: UInt64?
    public let gasUsed: UInt64?
    public let hash: String
    public let isPending: Bool
    public let sender: String?
    public let success: Bool?
    /// Microseconds since the Unix epoch.
    public let timestamp: UInt64?
    public let version: UInt64?
    public let vmStatus: String?

    /// `gasUsed × gasUnitPrice`, in octas, once committed.
    public var fee: UInt64? {
        guard let gasUsed, let gasUnitPrice else {
            return nil
        }

        return gasUsed * gasUnitPrice
    }
}

public extension AptosClient {
    func ledgerInfo() async throws -> AptosLedgerInfo {
        try await get("")
    }

    /// The next sequence number for `account`. Accounts that don't exist yet
    /// (stateless) report 0.
    func sequenceNumber(of account: AptosAddress) async throws -> UInt64 {
        let response: AccountResponse = try await get("accounts/\(account.longString)")
        return response.sequenceNumber
    }

    /// `owner`'s balance of `assetType`: a coin type or a Fungible Asset
    /// metadata address.
    func balance(of owner: AptosAddress, assetType: String) async throws -> UInt64 {
        let data = try await requestData(.get(url: url("accounts/\(owner.longString)/balance/\(assetType)"), headers: headers))
        let text = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

        guard let value = UInt64(text.trimmingCharacters(in: CharacterSet(charactersIn: "\""))) else {
            throw BlockchainClientError.decodingFailed(reason: "unexpected Aptos balance: \(text)")
        }

        return value
    }

    func estimateGasPrice() async throws -> AptosGasPriceEstimate {
        try await get("estimate_gas_price")
    }

    /// Simulates `rawTransaction` with `authenticator` (see
    /// `AptosSignerFfi.simulationAuthenticator`).
    func simulate(rawTransaction: Data, authenticator: Data) async throws -> AptosSimulation {
        let data = try await requestData(.post(
            url: url("transactions/simulate"),
            headers: headers.merging(["Content-Type": Self.signedTransactionContentType]) { $1 },
            body: rawTransaction + authenticator
        ))
        let results = try JSONDecoder().decode([UserTransactionResponse].self, from: data)

        guard let result = results.first, let gasUsed = result.gasUsed, let price = result.gasUnitPrice else {
            throw BlockchainClientError.decodingFailed(reason: "Aptos simulation returned no result")
        }

        return AptosSimulation(
            gasUnitPrice: price,
            gasUsed: gasUsed,
            success: result.success ?? false,
            vmStatus: result.vmStatus ?? ""
        )
    }

    func transaction(byHash hash: String) async throws -> AptosTransactionStatus? {
        do {
            let response: UserTransactionResponse = try await get("transactions/by_hash/\(hash)")
            return response.status
        } catch AptosHTTPError.notFound {
            return nil
        }
    }

    func transaction(byVersion version: UInt64) async throws -> AptosTransactionStatus {
        let response: UserTransactionResponse = try await get("transactions/by_version/\(version)")
        return response.status
    }

    /// Polls until `hash` is committed or `timeout` elapses.
    ///
    /// - Returns: The committed transaction, or `nil` on timeout.
    func waitForTransaction(_ hash: String, timeout: Duration = .seconds(30)) async throws -> AptosTransactionStatus? {
        let deadline = ContinuousClock.now.advanced(by: timeout)

        while ContinuousClock.now < deadline {
            if let status = try await transaction(byHash: hash), !status.isPending {
                return status
            }

            // `_Concurrency.` because Moya also defines `Task`.
            try await _Concurrency.Task.sleep(for: .milliseconds(250))
        }

        return nil
    }

    /// Submits BCS `SignedTransaction` bytes, returning the transaction hash.
    func submit(signedTransaction: Data) async throws -> String {
        let hash = Self.transactionHash(of: signedTransaction)

        do {
            let data = try await requestData(.post(
                url: url("transactions"),
                headers: headers.merging(["Content-Type": Self.signedTransactionContentType]) { $1 },
                body: signedTransaction
            ))
            let response = try JSONDecoder().decode(PendingTransactionResponse.self, from: data)
            return response.hash
        } catch let AptosHTTPError.rejected(_, code?, _) where Self.alreadySubmittedCodes.contains(code) {
            // A 429/503 retry can land after the first attempt was accepted.
            return hash
        }
    }
}

// MARK: - BlockchainClientProtocol

extension AptosClient {
    public func getAllBalances(_ owner: AptosAddress) async throws -> [String: BigUInt] {
        try await indexedBalances(of: owner).reduce(into: [:]) { result, balance in
            result[balance.assetType] = balance.amount
        }
    }

    public func getBalances(_ owner: AptosAddress, tokens: [String]) async throws -> [String: BigUInt] {
        let requested = Set(tokens.map(Self.canonicalAssetType))
        return try await getAllBalances(owner).filter { requested.isEmpty || requested.contains($0.key) }
    }

    public func getBalance(_ owner: AptosAddress, token: String) async throws -> BigUInt {
        BigUInt(try await balance(of: owner, assetType: Self.canonicalAssetType(token)))
    }

    public func getNativeBalance(_ owner: AptosAddress) async throws -> BigUInt {
        BigUInt(try await balance(of: owner, assetType: Self.nativeCoinType))
    }

    public func getTokenInfo(_ token: String?) async throws -> TokenInfo {
        guard let token, !Self.isNativeAsset(token) else {
            return .aptos
        }

        return try await tokenMetadata(Self.canonicalAssetType(token))
    }

    public func isActiveAccount(_ owner: AptosAddress) async throws -> Bool {
        if try await sequenceNumber(of: owner) > 0 {
            return true
        }

        if indexerURL != nil {
            return try await !indexedBalances(of: owner).isEmpty
        }

        return try await getNativeBalance(owner) > 0
    }

    public func isSupported(_ feature: BlockchainClientFeature) -> Bool {
        switch feature {
        case .allBalances, .multipleBalances, .transactionHistory: indexerURL != nil
        case .transactionSubscription: false
        }
    }

    /// Submits `transaction` (BCS `RawTransaction`) with `signature` (BCS
    /// `TransactionAuthenticator` from ``AptosPKeySigner/sign(transaction:)``).
    public func broadcast(transaction: Data, signature: Data) async throws -> String {
        try await submit(signedTransaction: transaction + signature)
    }
}

// MARK: - Indexer

struct AptosIndexedBalance: Sendable {
    let amount: BigUInt
    /// Canonical identifier (see `AptosClient.canonicalAssetType`).
    let assetType: String
    /// The Fungible Asset metadata address paired with a coin type, if any.
    let fungibleAssetType: String?
}

extension AptosClient {
    func indexedBalances(of owner: AptosAddress) async throws -> [AptosIndexedBalance] {
        let response: BalancesResponse = try await graphQL(
            """
            query Balances($owner: String!) {
              current_fungible_asset_balances(where: {owner_address: {_eq: $owner}, amount: {_gt: "0"}}) {
                amount asset_type asset_type_v2
              }
            }
            """,
            variables: ["owner": owner.longString]
        )

        return response.currentFungibleAssetBalances.compactMap { row in
            guard let amount = BigUInt(row.amount.description) else {
                return nil
            }

            return AptosIndexedBalance(
                amount: amount,
                assetType: Self.canonicalAssetType(row.assetType),
                fungibleAssetType: row.assetTypeV2.map(Self.canonicalAssetType)
            )
        }
    }

    func tokenMetadata(_ assetType: String) async throws -> TokenInfo {
        let response: MetadataResponse = try await graphQL(
            """
            query Metadata($assetType: String!) {
              fungible_asset_metadata(where: {asset_type: {_eq: $assetType}}) { decimals name symbol }
            }
            """,
            variables: ["assetType": assetType]
        )

        guard let metadata = response.fungibleAssetMetadata.first else {
            throw BlockchainClientError.decodingFailed(reason: "no Aptos metadata for \(assetType)")
        }

        return TokenInfo(decimals: metadata.decimals, name: metadata.name, isNative: false, symbol: metadata.symbol)
    }

    func graphQL<Response: Decodable>(_ query: String, variables: [String: any Sendable]) async throws -> Response {
        guard let indexerURL else {
            throw WalletKitError.unsupportedFeature
        }

        let body = try JSONSerialization.data(withJSONObject: ["query": query, "variables": variables])
        let data = try await requestData(.post(
            url: indexerURL,
            headers: headers.merging(["Content-Type": "application/json"]) { $1 },
            body: body
        ))
        let envelope = try JSONDecoder().decode(GraphQLEnvelope<Response>.self, from: data)

        if let message = envelope.errors?.first?.message {
            throw BlockchainClientError.rpcError(code: 0, message: message)
        }

        guard let result = envelope.data else {
            throw BlockchainClientError.invalidResponse(reason: "Aptos indexer returned no data")
        }

        return result
    }
}

// MARK: - Responses

private struct AccountResponse: Decodable {
    let sequenceNumber: UInt64

    enum CodingKeys: String, CodingKey {
        case sequenceNumber = "sequence_number"
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        sequenceNumber = try container.decodeNumericString(forKey: .sequenceNumber)
    }
}

private struct PendingTransactionResponse: Decodable {
    let hash: String
}

private struct UserTransactionResponse: Decodable {
    struct Payload: Decodable {
        let function: String?
    }

    let gasUnitPrice: UInt64?
    let gasUsed: UInt64?
    let hash: String
    let payload: Payload?
    let sender: String?
    let success: Bool?
    let timestamp: UInt64?
    /// Absent in `/transactions/simulate` results.
    let type: String?
    let version: UInt64?
    let vmStatus: String?

    enum CodingKeys: String, CodingKey {
        case gasUnitPrice = "gas_unit_price"
        case gasUsed = "gas_used"
        case hash
        case payload
        case sender
        case success
        case timestamp
        case type
        case version
        case vmStatus = "vm_status"
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        gasUnitPrice = try container.decodeNumericStringIfPresent(forKey: .gasUnitPrice)
        gasUsed = try container.decodeNumericStringIfPresent(forKey: .gasUsed)
        hash = try container.decode(String.self, forKey: .hash)
        payload = try? container.decodeIfPresent(Payload.self, forKey: .payload)
        sender = try container.decodeIfPresent(String.self, forKey: .sender)
        success = try container.decodeIfPresent(Bool.self, forKey: .success)
        timestamp = try container.decodeNumericStringIfPresent(forKey: .timestamp)
        type = try container.decodeIfPresent(String.self, forKey: .type)
        version = try container.decodeNumericStringIfPresent(forKey: .version)
        vmStatus = try container.decodeIfPresent(String.self, forKey: .vmStatus)
    }

    var status: AptosTransactionStatus {
        AptosTransactionStatus(
            entryFunction: payload?.function,
            gasUnitPrice: gasUnitPrice,
            gasUsed: gasUsed,
            hash: hash,
            isPending: type == "pending_transaction",
            sender: sender,
            success: success,
            timestamp: timestamp,
            version: version,
            vmStatus: vmStatus
        )
    }
}

private struct GraphQLEnvelope<Payload: Decodable>: Decodable {
    struct GraphQLError: Decodable {
        let message: String
    }

    let data: Payload?
    let errors: [GraphQLError]?
}

private struct BalancesResponse: Decodable {
    struct Row: Decodable {
        let amount: AptosIndexerNumber
        let assetType: String
        let assetTypeV2: String?

        enum CodingKeys: String, CodingKey {
            case amount
            case assetType = "asset_type"
            case assetTypeV2 = "asset_type_v2"
        }
    }

    let currentFungibleAssetBalances: [Row]

    enum CodingKeys: String, CodingKey {
        case currentFungibleAssetBalances = "current_fungible_asset_balances"
    }
}

private struct MetadataResponse: Decodable {
    struct Row: Decodable {
        let decimals: UInt8
        let name: String
        let symbol: String
    }

    let fungibleAssetMetadata: [Row]

    enum CodingKeys: String, CodingKey {
        case fungibleAssetMetadata = "fungible_asset_metadata"
    }
} // swiftlint:disable:this file_length
