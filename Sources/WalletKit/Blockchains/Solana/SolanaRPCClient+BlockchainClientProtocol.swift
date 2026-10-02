//
//  SolanaRPCClient+BlockchainClientProtocol.swift
//  WalletKit
//
//  Created by Andrey Yurkevich on 21/09/2026.
//  Copyright © 2026 Reefr Wallet. All rights reserved.
//

import BigInt
import Foundation

/// ``BlockchainClientProtocol`` conformance for ``SolanaRPCClient``.
extension SolanaRPCClient: BlockchainClientProtocol {
    public typealias Address = SolanaAddress

    /// Wrapped SOL's real mint address, used here purely as a sentinel
    /// key/token-identifier for native SOL — never queried as an actual
    /// SPL mint.
    static let nativeMintPlaceholder = SolanaAddress.known("So11111111111111111111111111111111111111112")

    public func getAllBalances(_ owner: SolanaAddress) async throws -> [String: BigUInt] {
        var balances: [String: BigUInt] = [
            Self.nativeMintPlaceholder.string: BigUInt(try await lamportBalance(of: owner))
        ]

        for account in try await tokenAccounts(of: owner, tokenProgram: SolanaProgram.token) {
            balances[account.mint.string, default: 0] += account.amount
        }

        for account in try await tokenAccounts(of: owner, tokenProgram: SolanaProgram.token2022) {
            balances[account.mint.string, default: 0] += account.amount
        }

        return balances
    }

    public func getBalances(_ owner: SolanaAddress, tokens: [String]) async throws -> [String: BigUInt] {
        let all = try await getAllBalances(owner)
        guard !tokens.isEmpty else {
            return all
        }

        return all.filter { tokens.contains($0.key) }
    }

    public func getBalance(_ owner: SolanaAddress, token: String) async throws -> BigUInt {
        if token == Self.nativeMintPlaceholder.string {
            return BigUInt(try await lamportBalance(of: owner))
        }

        let mint = try SolanaAddress(string: token)
        let accounts = try await tokenAccounts(of: owner, tokenProgram: SolanaProgram.token)
            + tokenAccounts(of: owner, tokenProgram: SolanaProgram.token2022)

        return accounts.filter { $0.mint == mint }.reduce(0) { $0 + $1.amount }
    }

    public func getNativeBalance(_ owner: SolanaAddress) async throws -> BigUInt {
        BigUInt(try await lamportBalance(of: owner))
    }

    public func getTokenInfo(_ token: String?) async throws -> TokenInfo {
        guard let token, token != Self.nativeMintPlaceholder.string else {
            return .solana
        }

        let mint = try SolanaAddress(string: token)
        let decimals = try await mintDecimals(of: mint)

        guard let metadata = try? await metaplexTokenInfo(of: mint) else {
            let short = mint.string.prefix(4) + "…" + mint.string.suffix(4)
            return TokenInfo(decimals: decimals, name: String(short), isNative: false, symbol: String(short))
        }

        return TokenInfo(decimals: decimals, name: metadata.name, isNative: false, symbol: metadata.symbol)
    }

    public func getTokenPrice(_ token: String?) async throws -> Decimal {
        throw WalletKitError.unsupportedFeature
    }

    public func isActiveAccount(_ owner: SolanaAddress) async throws -> Bool {
        try await lamportBalance(of: owner) > 0
    }

    public func isSupported(_ feature: BlockchainClientFeature) -> Bool {
        switch feature {
        case .multipleBalances, .allBalances, .feeEstimation, .transactionHistory:
            true
        case .transactionSubscription:
            false
        }
    }

    /// Estimates the total lamport cost of the transfer encoded in
    /// `request.data` — the ``SolanaUnsignedTransaction`` envelope
    /// ``SolanaTransactionBuilder`` produces.
    ///
    /// Pass `nil` (or a `request` with `data == nil`) for a rates-only
    /// estimate: ``FeeEstimate/gasPrice`` is the current median recent
    /// priority fee (micro-lamports per compute unit);
    /// ``FeeEstimate/gasLimit``/``FeeEstimate/estimatedFee`` are `nil`.
    ///
    /// With a request: ``FeeEstimate/estimatedFee`` is `getFeeForMessage`'s
    /// base fee (5 000 lamports per required signature) plus the
    /// priority fee implied by any `ComputeBudget` instructions already
    /// compiled into the message; ``FeeEstimate/gasLimit`` is that
    /// message's compute-unit limit, if set.
    public func estimateFee(for request: FeeEstimateRequest<SolanaAddress>?) async throws -> FeeEstimate {
        guard let envelopeData = request?.data else {
            return FeeEstimate(gasPrice: BigUInt(try await recentPrioritizationFee()))
        }

        let envelope = try JSONDecoder().decode(SolanaUnsignedTransaction.self, from: envelopeData)
        let message = try SolanaMessage(serialized: envelope.message)
        let (computeUnitLimit, microLamportsPrice) = Self.computeBudget(in: message)

        let baseFee = try await feeForMessage(envelope.message)
            ?? UInt64(message.header.numRequiredSignatures) * 5_000
        let priorityFee = computeUnitLimit.map { limit in
            (UInt64(limit) * microLamportsPrice + 999_999) / 1_000_000
        } ?? 0

        return FeeEstimate(
            gasPrice: BigUInt(microLamportsPrice),
            gasLimit: computeUnitLimit.map { BigUInt($0) },
            estimatedFee: BigUInt(baseFee + priorityFee)
        )
    }

    /// Broadcasts a transaction: combines `signature` (the raw 64-byte
    /// ed25519 signature from ``SolanaPKeySigner``/``SolanaTrezorSigner``)
    /// with the message bytes decoded from `transaction`'s
    /// ``SolanaUnsignedTransaction`` envelope into the wire-format
    /// transaction (`compact-u16(1) || signature || message`), and
    /// submits it via `sendTransaction`.
    ///
    /// - Returns: The transaction's signature, Base58-encoded — Solana
    ///   has no separate transaction hash; the signature itself is the
    ///   identifier.
    public func broadcast(transaction: Data, signature: Data) async throws -> String {
        guard signature.count == 64 else {
            throw WalletKitError.signingFailed(reason: "A Solana signature must be 64 bytes.")
        }

        let envelope = try JSONDecoder().decode(SolanaUnsignedTransaction.self, from: transaction)
        var wire = SolanaShortVec.encode(1)

        wire.append(signature)
        wire.append(envelope.message)

        return try await sendTransaction(wire)
    }

    /// Extracts `(computeUnitLimit, microLamportsPrice)` from any
    /// `SetComputeUnitLimit`/`SetComputeUnitPrice` instructions already
    /// compiled into `message` — `nil`/`0` for whichever wasn't set.
    private static func computeBudget(in message: SolanaMessage) -> (limit: UInt32?, microLamports: UInt64) {
        var limit: UInt32?
        var microLamports: UInt64 = 0

        let computeBudgetIndex = message
            .accountKeys
            .firstIndex { $0 == SolanaProgram.computeBudget }

        guard let computeBudgetIndex, let programIndex = UInt8(exactly: computeBudgetIndex) else {
            return (nil, 0)
        }

        for instruction in message.instructions where instruction.programIdIndex == programIndex {
            guard !instruction.data.isEmpty else {
                continue
            }

            let discriminant = instruction.data[0]
            let payload = Array(instruction.data.dropFirst())

            if discriminant == 2, payload.count == 4 {
                limit = littleEndian(payload)
            } else if discriminant == 3, payload.count == 8 {
                microLamports = littleEndian(payload)
            }
        }

        return (limit, microLamports)
    }

    /// Decodes `bytes` as a little-endian unsigned integer — used instead
    /// of `withUnsafeBytes(_:).load(as:)` because `bytes` comes from a
    /// `Data` slice with no alignment guarantee.
    private static func littleEndian<T: FixedWidthInteger>(_ bytes: [UInt8]) -> T {
        bytes.enumerated().reduce(T(0)) { result, pair in result | T(pair.element) << (8 * pair.offset) }
    }
}
