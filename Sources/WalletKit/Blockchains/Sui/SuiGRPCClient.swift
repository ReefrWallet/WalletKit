//
//  SuiGRPCClient.swift
//  WalletKit
//
//  Created by Andrey Yurkevich on 17/08/2026.
//  Copyright © 2026 Reefr Wallet. All rights reserved.
//

import BigInt
import Foundation
import GRPCCore
import GRPCNIOTransportHTTP2Posix
import SwiftProtobuf
import WalletKitGRPC

/// A client for Sui's gRPC full-node API.
public struct SuiGRPCClient: Sendable { // swiftlint:disable:this type_body_length
    private let host: String
    private let port: Int
    private let useTLS: Bool
    private let rpcTimeout: Int

    /// Creates a client for the gRPC full node at `host`.
    ///
    /// - Parameters:
    ///   - host: The full node's hostname (or IP address).
    ///   - port: The gRPC port. Defaults to `443`.
    ///   - useTLS: Whether to use TLS. Defaults to `true`.
    ///   - rpcTimeout: The deadline applied to every RPC, in seconds.
    public init(host: String, port: Int = 443, useTLS: Bool = true, rpcTimeout: Int = 10) {
        self.host = host
        self.port = port
        self.useTLS = useTLS
        self.rpcTimeout = rpcTimeout
    }

    var callOptions: GRPCCore.CallOptions {
        var options = GRPCCore.CallOptions.defaults
        options.timeout = .seconds(rpcTimeout)
        return options
    }

    /// Reads `address`'s balance of `coinType` — any Sui coin, not just
    /// native SUI.
    ///
    /// - Parameters:
    ///   - address: The account to read the balance of.
    ///   - coinType: The coin type, e.g. `"0x2::sui::SUI"`.
    /// - Returns: The balance, in the coin's smallest unit.
    /// - Throws: ``BlockchainClientError`` on a transport, RPC, or
    ///   decoding failure.
    public func coinBalance(of address: SuiAddress, coinType: String = "0x2::sui::SUI") async throws -> UInt64 {
        try await withStateServiceClient { client in
            let request = Sui_Rpc_V2_GetBalanceRequest.with {
                $0.owner = address.string
                $0.coinType = coinType
            }

            let response = try await client.getBalance(
                request: ClientRequest(message: request),
                options: self.callOptions
            )

            return response.balance.balance
        }
    }

    public func listAllBalances(of address: SuiAddress) async throws -> [Sui_Rpc_V2_Balance] {
        try await withStateServiceClient { client in
            let request = Sui_Rpc_V2_ListBalancesRequest.with {
                $0.owner = address.string
            }

            let response = try await client.listBalances(
                request: ClientRequest(message: request),
                options: self.callOptions
            )

            return response.balances
        }
    }

    /// Reads `coinType`'s metadata — name, symbol, and decimals.
    ///
    /// - Parameter coinType: The coin type, e.g. `"0x2::sui::SUI"`.
    /// - Returns: The coin's metadata.
    /// - Throws: ``BlockchainClientError`` on a transport, RPC, or
    ///   decoding failure.
    public func coinInfo(coinType: String = "0x2::sui::SUI") async throws -> TokenInfo {
        try await withStateServiceClient { client in
            let request = Sui_Rpc_V2_GetCoinInfoRequest.with {
                $0.coinType = coinType
            }

            let response = try await client.getCoinInfo(
                request: ClientRequest(message: request),
                options: self.callOptions
            )

            let isNative = try MoveTypeTag.canonicalCoinType(coinType)
                == MoveTypeTag.canonicalCoinType("0x2::sui::SUI")

            return TokenInfo(
                decimals: UInt8(response.metadata.decimals),
                name: response.metadata.name,
                isNative: isNative,
                symbol: response.metadata.symbol
            )
        }
    }

    /// Reads `address`'s native SUI balance —
    /// ``coinBalance(of:coinType:)`` with the default `"0x2::sui::SUI"`
    /// coin type.
    ///
    /// - Parameter address: The account to read the balance of.
    /// - Returns: The balance, in MIST (SUI's smallest unit).
    /// - Throws: ``BlockchainClientError`` on a transport, RPC, or
    ///   decoding failure.
    public func nativeBalance(of address: SuiAddress) async throws -> UInt64 {
        try await coinBalance(of: address)
    }

    /// Lists objects owned by `owner`.
    ///
    /// - Parameter owner: The account to list owned objects for.
    /// - Returns: The owner's objects (a single page — up to the node's
    ///   default page size).
    /// - Throws: ``BlockchainClientError`` on a transport, RPC, or
    ///   decoding failure.
    public func getOwnedObjects(_ owner: SuiAddress) async throws -> [Sui_Rpc_V2_Object] {
        try await withStateServiceClient { client in
            let request = Sui_Rpc_V2_ListOwnedObjectsRequest.with {
                $0.owner = owner.string
            }

            let response = try await client.listOwnedObjects(
                request: ClientRequest(message: request),
                options: self.callOptions
            )

            return response.objects
        }
    }

    /// Reads a Move object's on-chain state directly — the general
    /// "read arbitrary object data" entry point. ``cetusPoolPrice(pool:token:)``
    /// is a worked example built on this; a caller with a different
    /// object interprets `object.json`/`object.objectType`/
    /// `object.contents` itself. Unlike
    /// ``EthereumRPCClient/call(to:data:)``, this needs no simulated
    /// execution — a Sui object's fields are plain on-chain data,
    /// directly queryable, not storage a getter function has to run
    /// against.
    ///
    /// - Parameters:
    ///   - id: The object's ID.
    ///   - readMask: Which of the object's fields to populate, e.g.
    ///     `["json", "object_type"]`. Defaults to the node's own default
    ///     (`object_id,version,digest`) when empty.
    /// - Returns: The object.
    /// - Throws: ``BlockchainClientError`` on a transport, RPC, or
    ///   decoding failure.
    public func object(id: String, readMask: [String] = []) async throws -> Sui_Rpc_V2_Object {
        try await withLedgerServiceClient { client in
            let request = Sui_Rpc_V2_GetObjectRequest.with {
                $0.objectID = id
                if !readMask.isEmpty {
                    $0.readMask = Google_Protobuf_FieldMask.with { $0.paths = readMask }
                }
            }

            let response = try await client.getObject(
                request: ClientRequest(message: request),
                options: self.callOptions
            )

            return response.object
        }
    }

    /// Fetches multiple objects in one round trip via
    /// `LedgerService.batchGetObjects` — used to resolve a dapp
    /// transaction's unresolved object inputs (owner kind, shared
    /// `initial_shared_version`) before it can be built into BCS.
    ///
    /// - Parameters:
    ///   - ids: The objects' IDs. The node imposes its own cap on
    ///     request count; callers should batch at a reasonable size
    ///     (e.g. 50) themselves.
    ///   - readMask: Which fields to populate. Defaults to
    ///     `object_id,version,digest,owner`.
    /// - Returns: One object per input id, in the same order as `ids`.
    /// - Throws: ``BlockchainClientError`` on a transport, RPC, or
    ///   decoding failure, or if any individual object lookup failed
    ///   (e.g. the object doesn't exist) — there is no partial result.
    public func objects(ids: [String]) async throws -> [SuiObjectInfo] {
        try await withLedgerServiceClient { client in
            let request = Sui_Rpc_V2_BatchGetObjectsRequest.with {
                $0.requests = ids.map { id in
                    Sui_Rpc_V2_GetObjectRequest.with {
                        $0.objectID = id
                        $0.readMask = Google_Protobuf_FieldMask.with {
                            $0.paths = ["object_id", "version", "digest", "owner"]
                        }
                    }
                }
            }

            let response = try await client.batchGetObjects(
                request: ClientRequest(message: request),
                options: self.callOptions
            )

            return try response.objects.map { result in
                guard case .object(let object)? = result.result else {
                    throw BlockchainClientError.decodingFailed(reason: "object lookup failed: \(result.error.message)")
                }

                let owner: SuiObjectInfo.Owner

                switch object.owner.kind {
                case .address:
                    owner = .address(try SuiAddress(string: object.owner.address))
                case .object:
                    owner = .object(try SuiAddress(string: object.owner.address))
                case .immutable:
                    owner = .immutable
                case .shared:
                    owner = .shared(initialSharedVersion: object.owner.version)
                case .unknown, .consensusAddress, .UNRECOGNIZED:
                    owner = .unsupported
                }

                return SuiObjectInfo(
                    objectId: try Data(hexString: object.objectID),
                    version: object.version,
                    digest: try Base58.decode(object.digest),
                    owner: owner
                )
            }
        }
    }

    /// Reads a Move function's signature via
    /// `MovePackageService.getFunction` — used to resolve a dapp
    /// transaction's untyped `MoveCall` arguments (pure-value BCS
    /// encoding, shared-object mutability) before it can be built into
    /// BCS.
    ///
    /// - Parameters:
    ///   - package: The function's package ID.
    ///   - module: The function's module name.
    ///   - name: The function name.
    /// - Returns: The function's descriptor, including its parameter
    ///   types.
    /// - Throws: ``BlockchainClientError`` on a transport, RPC, or
    ///   decoding failure.
    public func moveFunction(package: String, module: String, name: String) async throws -> SuiMoveFunctionSignature {
        try await withMovePackageServiceClient { client in
            let request = Sui_Rpc_V2_GetFunctionRequest.with {
                $0.packageID = package
                $0.moduleName = module
                $0.name = name
            }

            let response = try await client.getFunction(
                request: ClientRequest(message: request),
                options: self.callOptions
            )

            return SuiMoveFunctionSignature(parameters: response.function.parameters.map(Self.convert))
        }
    }

    private static func convert(_ signature: Sui_Rpc_V2_OpenSignature) -> SuiMoveParameter {
        let reference: SuiMoveParameter.Reference

        switch signature.reference {
        case .immutable:
            reference = .immutable
        case .mutable:
            reference = .mutable
        case .unknown, .UNRECOGNIZED:
            reference = .none
        }

        return SuiMoveParameter(reference: reference, body: convert(signature.body))
    }

    private static func convert(_ body: Sui_Rpc_V2_OpenSignatureBody) -> SuiMoveTypeBody {
        switch body.type {
        case .address:
            return .address
        case .bool:
            return .bool
        case .u8:
            return .u8
        case .u16:
            return .u16
        case .u32:
            return .u32
        case .u64:
            return .u64
        case .u128:
            return .u128
        case .u256:
            return .u256
        case .datatype:
            return .datatype(typeName: body.typeName, typeParameters: body.typeParameterInstantiation.map(convert))
        case .parameter:
            return .typeParameter(Int(body.typeParameter))
        case .vector:
            guard let element = body.typeParameterInstantiation.first else {
                return .unsupported
            }

            return .vector(convert(element))
        case .unknown, .UNRECOGNIZED:
            return .unsupported
        }
    }

    /// Reads a Cetus CLMM pool's current spot price for `token`, in
    /// terms of the pool's other coin — Cetus's `current_sqrt_price`, a
    /// Q64.64 fixed-point value read directly off the shared
    /// `Pool<CoinTypeA, CoinTypeB>` object via ``object(id:readMask:)``.
    ///
    /// - Note: This is Cetus's *current* price, not a time-weighted
    ///   average the way ``EthereumRPCClient/uniswapV3TWAPPrice(token:pool:period:)``
    ///   reads Uniswap V3's — Cetus doesn't publish a verified, stable
    ///   single-call on-chain TWAP read analogous to Uniswap V3's
    ///   `observe(uint32[])`.
    ///
    /// - Parameters:
    ///   - pool: The Cetus `Pool` object's ID.
    ///   - token: The coin type to price, e.g. `"0x2::sui::SUI"` — must
    ///     match one of the pool's two generic coin type arguments
    ///     (short or long address form; both are normalized before
    ///     comparing).
    /// - Returns: The current price of one (human-unit) `token`, in
    ///   human-unit terms of the pool's other coin.
    /// - Throws: ``BlockchainClientError/decodingFailed(reason:)`` if
    ///   `token` matches neither of the pool's coin types, the object
    ///   isn't a `Pool<CoinTypeA, CoinTypeB>`, or it has no readable
    ///   `current_sqrt_price`, or ``BlockchainClientError`` on a
    ///   transport, RPC, or other decoding failure.
    public func cetusPoolPrice(pool: String, token: String) async throws -> Double {
        let poolObject = try await object(id: pool, readMask: ["object_type", "json"])

        let coinTypes = try MoveTypeTag.genericTypeArguments(of: poolObject.objectType)
        guard coinTypes.count == 2 else {
            throw BlockchainClientError.decodingFailed(
                reason: "expected a Pool<CoinTypeA, CoinTypeB> object, got \(poolObject.objectType)"
            )
        }

        let coinTypeA = try MoveTypeTag.canonicalCoinType(coinTypes[0])
        let coinTypeB = try MoveTypeTag.canonicalCoinType(coinTypes[1])
        let normalizedToken = try MoveTypeTag.canonicalCoinType(token)

        guard normalizedToken == coinTypeA || normalizedToken == coinTypeB else {
            throw BlockchainClientError.decodingFailed(reason: "token is neither of the pool's two coin types")
        }

        guard case .stringValue(let sqrtPriceString)? = poolObject.json.structValue.fields["current_sqrt_price"]?.kind,
              let sqrtPriceX64 = BigUInt(sqrtPriceString)
        else {
            throw BlockchainClientError.decodingFailed(reason: "pool object has no readable current_sqrt_price")
        }

        async let coinACall = coinInfo(coinType: coinTypeA)
        async let coinBCall = coinInfo(coinType: coinTypeB)
        let coinADecimals = try await coinACall.decimals
        let coinBDecimals = try await coinBCall.decimals

        // Decimals relative to `token`/its quote coin, not fixed to
        // coinA/coinB order — the adjustment's sign has to flip along
        // with the price direction below, the same way
        // `EthereumRPCClient.uniswapV3TWAPPrice`'s does.
        let tokenDecimals = normalizedToken == coinTypeA ? coinADecimals : coinBDecimals
        let quoteDecimals = normalizedToken == coinTypeA ? coinBDecimals : coinADecimals

        // Raw price of one smallest-unit of coinA in smallest-units of
        // coinB; adjusting by each side's decimals gives the
        // human-readable price in the requested direction.
        let sqrtPrice = Double(sqrtPriceX64) / pow(2, 64)
        let rawCoinAInCoinB = sqrtPrice * sqrtPrice
        let decimalsAdjustment = pow(10, Double(Int(tokenDecimals) - Int(quoteDecimals)))

        return normalizedToken == coinTypeA
            ? rawCoinAInCoinB * decimalsAdjustment
            : decimalsAdjustment / rawCoinAInCoinB
    }

    /// Broadcasts an already-signed transaction.
    ///
    /// - Parameters:
    ///   - transactionData: The raw BCS-encoded `TransactionData` bytes
    ///     that were signed, e.g. the bytes passed to
    ///     ``SuiPKeySigner/sign(transaction:)``.
    ///   - signature: The serialized signature over `transactionData`,
    ///     e.g. from ``SuiPKeySigner/sign(transaction:)``.
    /// - Returns: The executed transaction's digest.
    /// - Throws: ``BlockchainClientError`` on a transport, RPC, or
    ///   decoding failure.
    public func broadcast(transactionData: Data, signature: Data) async throws -> String {
        try await withTransactionExecutionServiceClient { client in
            let request = Sui_Rpc_V2_ExecuteTransactionRequest.with {
                $0.transaction = Sui_Rpc_V2_Transaction.with {
                    $0.bcs = Sui_Rpc_V2_Bcs.with { $0.value = transactionData }
                }

                $0.signatures = [
                    Sui_Rpc_V2_UserSignature.with {
                        $0.bcs = Sui_Rpc_V2_Bcs.with { $0.value = signature }
                    }

                ]

                // The default read mask (`effects.status,checkpoint`) omits
                // `digest` entirely, so without this the returned digest is
                // empty and unusable for a follow-up `GetTransaction` call.
                $0.readMask.paths = ["digest"]
            }

            let response = try await client.executeTransaction(
                request: ClientRequest(message: request),
                options: self.callOptions
            )

            return response.transaction.digest
        }
    }

    /// Executes a signed transaction exactly like ``broadcast(transactionData:signature:)``,
    /// but also requests and returns the transaction's raw BCS-encoded
    /// `TransactionEffects` from the same execute call — no separate
    /// follow-up RPC — for callers that need the full Wallet Standard
    /// `sui:signAndExecuteTransaction` response shape (`bytes`,
    /// `signature`, `digest`, `effects`), not just a digest.
    ///
    /// This is a Sui-specific extra, not part of
    /// ``BlockchainClientProtocol`` — every other chain's broadcast only
    /// ever returns an identifier string, and adding an effects-shaped
    /// return to that shared, cross-chain protocol would be a much
    /// larger, unrelated change.
    ///
    /// - Parameters:
    ///   - transactionData: The raw BCS-encoded `TransactionData` bytes.
    ///   - signature: The serialized signature over `transactionData`.
    /// - Returns: The executed transaction's digest and raw BCS-encoded
    ///   `TransactionEffects`.
    /// - Throws: ``BlockchainClientError`` on a transport, RPC, or
    ///   decoding failure.
    public func executeTransactionWithEffects(
        transactionData: Data, signature: Data
    ) async throws -> (digest: String, effects: Data) {
        try await withTransactionExecutionServiceClient { client in
            let request = Sui_Rpc_V2_ExecuteTransactionRequest.with {
                $0.transaction = Sui_Rpc_V2_Transaction.with {
                    $0.bcs = Sui_Rpc_V2_Bcs.with { $0.value = transactionData }
                }

                $0.signatures = [
                    Sui_Rpc_V2_UserSignature.with {
                        $0.bcs = Sui_Rpc_V2_Bcs.with { $0.value = signature }
                    }

                ]

                $0.readMask.paths = ["digest", "transaction.effects.bcs"]
            }

            let response = try await client.executeTransaction(
                request: ClientRequest(message: request),
                options: self.callOptions
            )

            return (digest: response.transaction.digest, effects: response.transaction.effects.bcs.value)
        }
    }

    /// Lists all owned `Coin<coinType>` objects for `address`, sorted by
    /// balance descending (largest first).
    ///
    /// Uses `StateService.listOwnedObjects` with an `objectType` filter of
    /// `"0x2::coin::Coin<coinType>"` and reads `objectId`, `version`,
    /// `digest`, and `balance` for each result. Object IDs are decoded from
    /// `0x`-hex with a local hexadecimal decoder; digests from Base58 (the Sui
    /// gRPC API uses Base58 for digests, unlike `0x`-hex everywhere else).
    ///
    /// - Parameters:
    ///   - address: The account to list coins for.
    ///   - coinType: The coin type to query, e.g. `"0x2::sui::SUI"` or a
    ///     custom Move coin type string.
    /// - Returns: The account's owned coins of the given type, each carrying
    ///   an object reference and balance, sorted largest-balance-first.
    /// - Throws: ``BlockchainClientError`` on a transport, RPC, or decoding
    ///   failure.
    public func ownedCoins(of address: SuiAddress, coinType: String) async throws -> [SuiCoinObject] {
        try await withStateServiceClient { stateClient in
            var coins: [SuiCoinObject] = []
            var pageToken = Data()

            repeat {
                let pageRequest = Sui_Rpc_V2_ListOwnedObjectsRequest.with {
                    $0.owner = address.string
                    $0.objectType = "0x2::coin::Coin<\(coinType)>"
                    $0.readMask = Google_Protobuf_FieldMask.with {
                        $0.paths = ["object_id", "version", "digest", "balance"]
                    }

                    if !pageToken.isEmpty { $0.pageToken = pageToken }
                }

                let response = try await stateClient.listOwnedObjects(
                    request: ClientRequest(message: pageRequest),
                    options: self.callOptions
                )

                let page = try response.objects.map { object in
                    SuiCoinObject(
                        reference: SuiObjectReference(
                            objectId: try Data(hexString: object.objectID),
                            version: object.version,
                            digest: try Base58.decode(object.digest)
                        ),
                        balance: object.balance
                    )
                }

                coins.append(contentsOf: page)
                pageToken = response.nextPageToken
            } while !pageToken.isEmpty

            return coins.sorted {
                $0.balance > $1.balance
            }
        }
    }

    /// Returns current Sui network fee rates and, when `request.data` is
    /// non-nil, a per-transaction gas estimate via
    /// `TransactionExecutionService.simulateTransaction`.
    ///
    /// **Rates** are fetched from `LedgerService.getEpoch` as the epoch's
    /// `reference_gas_price` (MIST per gas unit), returned in
    /// ``FeeEstimate/gasPrice``. ``FeeEstimate/maxFeePerGas`` and
    /// ``FeeEstimate/maxPriorityFeePerGas`` are `nil` — Sui has no EIP-1559
    /// fee model.
    ///
    /// **Per-transaction estimate** (when `request.data` is non-nil): the
    /// BCS-encoded `TransactionData` bytes are passed to
    /// `simulateTransaction`. The ``FeeEstimate/estimatedFee`` is
    /// `computation_cost + storage_cost − storage_rebate` (floored at 0) from
    /// the simulation's `GasCostSummary`. ``FeeEstimate/gasLimit`` is
    /// `computation_cost ÷ reference_gas_price` (nil if the gas price is 0).
    ///
    /// - Parameter request: A ``FeeEstimateRequest`` whose `data` field
    ///   carries unsigned BCS `TransactionData` bytes, or `nil` for
    ///   rates-only.
    /// - Returns: A ``FeeEstimate`` with the reference gas price, plus per-tx
    ///   fields when `request.data` is non-nil.
    /// - Throws: ``BlockchainClientError`` on a transport, RPC, or decoding
    ///   failure.
    public func estimateFee(for request: FeeEstimateRequest<SuiAddress>?) async throws -> FeeEstimate {
        let gasPrice = try await referenceGasPrice()

        guard let txBytes = request?.data else {
            return FeeEstimate(gasPrice: BigUInt(gasPrice))
        }

        let gasCost = try await simulateGasCost(transactionData: txBytes)

        // Gross = computation + storage (before rebate). The rebate is
        // credited after execution, so the gas budget must cover the gross
        // cost; base any budget calculation on grossFee, not estimatedFee.
        let grossFee = BigUInt(gasCost.computationCost) + BigUInt(gasCost.storageCost)

        // Net fee = computation + storage − rebate, floored at 0. A negative
        // net is possible if the rebate exceeds both cost components (e.g. a
        // transaction that deletes many coin objects).
        let rawCost = Int64(bitPattern: gasCost.computationCost &+ gasCost.storageCost) - Int64(gasCost.storageRebate)

        let estimatedFee = BigUInt(max(0, rawCost))
        let gasLimit: BigUInt? = gasPrice > 0 ? BigUInt(gasCost.computationCost / gasPrice) : nil

        return FeeEstimate(
            gasPrice: BigUInt(gasPrice),
            gasLimit: gasLimit,
            estimatedFee: estimatedFee,
            grossFee: grossFee
        )
    }

    /// Fetches the current epoch's `reference_gas_price` (MIST per gas unit)
    /// via `LedgerService.getEpoch` with a narrow read mask.
    public func referenceGasPrice() async throws -> UInt64 {
        try await withLedgerServiceClient { ledger in
            let request = Sui_Rpc_V2_GetEpochRequest.with {
                $0.readMask = Google_Protobuf_FieldMask.with { $0.paths = ["reference_gas_price"] }
            }

            let response = try await ledger.getEpoch(
                request: ClientRequest(message: request),
                options: self.callOptions
            )

            return response.epoch.referenceGasPrice
        }
    }

    /// ``simulateGasCost(transactionData:)``, converted to
    /// ``SuiGasCostSummary`` — the dapp bridge's entry point for sizing
    /// a transaction's gas budget, kept distinct from
    /// ``estimateFee(for:)`` (which also fetches the reference gas
    /// price and computes a net, rebate-adjusted fee this budget-sizing
    /// use has no need for).
    public func gasCostSummary(transactionData: Data) async throws -> SuiGasCostSummary {
        let cost = try await simulateGasCost(transactionData: transactionData)
        return SuiGasCostSummary(
            computationCost: cost.computationCost, storageCost: cost.storageCost, storageRebate: cost.storageRebate
        )
    }

    /// Simulates `transactionData` via
    /// `TransactionExecutionService.simulateTransaction` and returns the
    /// resulting `GasCostSummary` (`computation_cost`, `storage_cost`,
    /// `storage_rebate`, `non_refundable_storage_fee`) — used both by
    /// ``estimateFee(for:)`` and ``gasCostSummary(transactionData:)``.
    func simulateGasCost(transactionData: Data) async throws -> Sui_Rpc_V2_GasCostSummary {
        try await withTransactionExecutionServiceClient { client in
            let request = Sui_Rpc_V2_SimulateTransactionRequest.with {
                $0.transaction = Sui_Rpc_V2_Transaction.with {
                    $0.bcs = Sui_Rpc_V2_Bcs.with { $0.value = transactionData }
                }

                // Request only the gas summary — avoids deserialising the
                // full object/event lists the node would otherwise populate.
                $0.readMask = Google_Protobuf_FieldMask.with {
                    $0.paths = ["transaction.effects.gas_used"]
                }
            }

            let response = try await client.simulateTransaction(
                request: ClientRequest(message: request),
                options: self.callOptions
            )

            return response.transaction.effects.gasUsed
        }
    }

    func transport() throws -> HTTP2ClientTransport.Posix {
        do {
            return try HTTP2ClientTransport.Posix(
                target: .dns(host: host, port: port),
                transportSecurity: useTLS ? .tls : .plaintext
            )
        } catch {
            throw BlockchainClientError.transportError(reason: error.localizedDescription)
        }
    }

    func withStateServiceClient<Result: Sendable>(
        _ body: @escaping (Sui_Rpc_V2_StateService.Client<HTTP2ClientTransport.Posix>) async throws -> Result
    ) async throws -> Result {
        try await withRemappedErrors {
            try await withGRPCClient(transport: try transport()) { grpcClient in
                try await body(Sui_Rpc_V2_StateService.Client(wrapping: grpcClient))
            }
        }
    }

    func withLedgerServiceClient<Result: Sendable>(
        _ body: @escaping (Sui_Rpc_V2_LedgerService.Client<HTTP2ClientTransport.Posix>) async throws -> Result
    ) async throws -> Result {
        try await withRemappedErrors {
            try await withGRPCClient(transport: try transport()) { grpcClient in
                try await body(Sui_Rpc_V2_LedgerService.Client(wrapping: grpcClient))
            }
        }
    }

    func withMovePackageServiceClient<Result: Sendable>(
        _ body: @escaping (Sui_Rpc_V2_MovePackageService.Client<HTTP2ClientTransport.Posix>) async throws -> Result
    ) async throws -> Result {
        try await withRemappedErrors {
            try await withGRPCClient(transport: try transport()) { grpcClient in
                try await body(Sui_Rpc_V2_MovePackageService.Client(wrapping: grpcClient))
            }
        }
    }

    func withTransactionExecutionServiceClient<Result: Sendable>(
        _ body: @escaping (Sui_Rpc_V2_TransactionExecutionService.Client<HTTP2ClientTransport.Posix>) async throws
            -> Result
    ) async throws -> Result {
        try await withRemappedErrors {
            try await withGRPCClient(transport: try transport()) { grpcClient in
                try await body(Sui_Rpc_V2_TransactionExecutionService.Client(wrapping: grpcClient))
            }
        }
    }

    func withSubscriptionServiceClient<Result: Sendable>(
        _ body: @escaping (Sui_Rpc_V2_SubscriptionService.Client<HTTP2ClientTransport.Posix>) async throws -> Result
    ) async throws -> Result {
        try await withRemappedErrors {
            try await withGRPCClient(transport: try transport()) { grpcClient in
                try await body(Sui_Rpc_V2_SubscriptionService.Client(wrapping: grpcClient))
            }
        }
    }
}

extension SuiGRPCClient {
    /// Runs `body`, translating a thrown `RPCError` (a gRPC `Status` the node
    /// returned) into ``BlockchainClientError/rpcError(code:message:)``.
    /// Already-thrown `BlockchainClientError`s (e.g. from `transport()`) pass
    /// through unchanged.
    func withRemappedErrors<Result: Sendable>(_ body: () async throws -> Result) async throws -> Result {
        do {
            return try await body()
        } catch let error as BlockchainClientError {
            throw error
        } catch let error as RPCError {
            throw BlockchainClientError.rpcError(code: error.code.rawValue, message: error.message)
        } catch {
            throw BlockchainClientError.transportError(reason: error.localizedDescription)
        }
    }
} // swiftlint:disable:this file_length
